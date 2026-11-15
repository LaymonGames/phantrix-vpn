// Per-application routing policy for the Windows OpenVPN path.
//
// ## What this is
//
// The elevated helper owns the tunnel, so it also owns the split-tunnel rules.
// The Flutter process never touches any of it.
//
// ## Why there is no kernel driver
//
// The first implementation redirected connections with an own WFP callout
// driver. Windows only loads kernel drivers that Microsoft has signed, so that
// driver loaded on a development machine with test signing enabled and nowhere
// else (`ERROR_INVALID_IMAGE_HASH`). This implementation needs no driver of its
// own: it runs the bundled sing-box router (GPL-3.0-or-later, the same licence
// family as Phantrix) as a child of the helper.
//
// sing-box creates a second Wintun adapter ("Phantrix Split") and takes the
// default route through it. Wintun is the Microsoft-signed driver OpenVPN
// already uses, so it loads on every supported Windows machine. Every
// connection that enters that adapter is matched against the selected
// executables' paths and leaves either through the OpenVPN adapter (bound to
// it by interface) or straight out through the physical network.
//
// ## The two modes
//
//   include: only the selected applications use the tunnel; everything else
//            leaves through the physical network.
//   exclude: everything uses the tunnel except the selected applications.
//
// In both modes OpenVPN's own full-tunnel routes are taken off the tunnel
// adapter while the router runs, and put back when it stops, so turning split
// tunnelling off in the middle of a session returns to a normal full tunnel.
//
// DNS always goes through the tunnel: Windows resolves names for every process
// in one service, so a per-application DNS split is not possible. sing-box's
// `strict_route` blocks Windows' multihomed DNS fallback to other adapters.

#ifndef PHANTRIX_SPLIT_TUNNEL_H_
#define PHANTRIX_SPLIT_TUNNEL_H_

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <netioapi.h>

#include <atomic>
#include <cstdint>
#include <functional>
#include <string>
#include <vector>

namespace phantrix {
namespace split {

// The router executable the build installs beside the helper.
constexpr wchar_t kRouterFileName[] = L"sing-box.exe";
// The name of the Wintun adapter the router creates.
constexpr wchar_t kRouterAdapterName[] = L"Phantrix Split";
// The kernel driver service an earlier build installed. Removed on sight.
constexpr wchar_t kLegacyDriverServiceName[] = L"PhantrixSplitTunnel";

// The policy as it arrives from the plugin.
struct Policy {
  bool enabled = false;
  bool include_mode = true;
  std::vector<std::wstring> apps;
};

// The router's full path, resolved from the helper's own directory only.
std::wstring RouterExecutable(const std::wstring& module_directory);
bool RouterPresent(const std::wstring& module_directory);

// Stops and deletes the kernel driver service an earlier build created, if it
// is still registered. Safe to call when it never existed.
void RemoveLegacyDriverService();

// Called on a thread-pool thread when the router exits without being asked to.
using ExitCallback =
    std::function<void(const std::string& code, const std::string& message)>;

class Controller {
 public:
  Controller() = default;
  ~Controller();

  Controller(const Controller&) = delete;
  Controller& operator=(const Controller&) = delete;

  // Who to tell when the router dies on its own. A router that is gone leaves
  // applications with no route through it, so the helper treats it as a
  // failed connection rather than a quiet change of routing.
  void SetUnexpectedExitCallback(ExitCallback callback);

  // Records the policy and checks that it can be applied at all: the router is
  // present and the selected executables still exist.
  //
  // Called before the engine starts, so a machine that cannot honour the
  // policy refuses the connection instead of bringing a tunnel up first.
  // `work_directory` is the session's private directory; the router's
  // configuration and log are written there.
  bool Prepare(const std::wstring& module_directory,
               const std::wstring& work_directory, const Policy& policy,
               std::string* error_code, std::string* error_message);

  // Applies the prepared policy to a connected tunnel.
  //
  // `tunnel_luid` is the Wintun adapter the engine is using. Called after the
  // engine reports its handshake, which is the first moment the adapter has an
  // address and DNS servers.
  bool Apply(NET_LUID tunnel_luid, std::string* error_code,
             std::string* error_message);

  // Stops the router and restores the tunnel's own routes. Safe to call
  // repeatedly.
  void Clear();

  // Clear, and forget the policy. Called on helper exit.
  void Shutdown();

  bool prepared() const { return prepared_; }
  bool applied() const { return process_ != nullptr; }

  // The router's adapter while it runs, so the kill switch can permit it.
  bool RouterLuid(NET_LUID* luid) const;

 private:
  bool WriteConfig(const std::wstring& tunnel_alias,
                   const std::string& dns_server, std::string* error_code,
                   std::string* error_message);
  bool StartRouter(std::string* error_code, std::string* error_message);
  void StopRouter();
  std::string RouterLogTail() const;

  void TakeTunnelRoutes(NET_LUID tunnel_luid);
  void RestoreTunnelRoutes();

  static void CALLBACK OnRouterExit(PVOID context, BOOLEAN timed_out);

  bool prepared_ = false;
  std::wstring module_directory_;
  std::wstring work_directory_;
  Policy policy_;

  ExitCallback on_exit_;
  std::atomic<bool> stopping_{false};

  HANDLE process_ = nullptr;
  HANDLE job_ = nullptr;
  HANDLE wait_ = nullptr;
  bool have_router_luid_ = false;
  NET_LUID router_luid_ = {};

  // Routes taken off the tunnel adapter, and the fallback default route added
  // to it, so both can be undone exactly.
  NET_LUID tunnel_luid_ = {};
  bool have_tunnel_ = false;
  std::vector<MIB_IPFORWARD_ROW2> removed_routes_;
  std::vector<MIB_IPFORWARD_ROW2> added_routes_;
};

}  // namespace split
}  // namespace phantrix

#endif  // PHANTRIX_SPLIT_TUNNEL_H_
