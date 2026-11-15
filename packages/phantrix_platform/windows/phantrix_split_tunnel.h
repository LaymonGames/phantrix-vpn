// Per-application routing policy for the Windows OpenVPN path.
//
// ## What this is
//
// The elevated helper owns the tunnel, so it also owns the split-tunnel rules:
// the driver service, the WFP filters and the extra route that include mode
// needs. The Flutter process never touches any of it.
//
// ## Why the rules are not in the driver
//
// The kernel component only redirects a connection's source address. Which
// applications are selected, and which address their traffic should leave
// from, is decided here and expressed as ordinary WFP filters with an
// application-ID condition. That keeps the kernel surface small: a filter can
// be inspected with the standard WFP tools, and a crashed helper takes its
// dynamic WFP session (and therefore every rule) with it.
//
// ## The two modes
//
//   include: the physical default route stays preferred, a single 0/0 route is
//            added through the tunnel at a high metric, and the selected
//            applications' connections are redirected to the tunnel address.
//   exclude: the tunnel keeps the full-tunnel routes it already installed, and
//            the selected applications' connections are redirected to the
//            physical address.
//
// Both are the same mechanism with a different target address, which is what
// makes one driver enough.

#ifndef PHANTRIX_SPLIT_TUNNEL_H_
#define PHANTRIX_SPLIT_TUNNEL_H_

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <fwpmu.h>
#include <netioapi.h>

#include <cstdint>
#include <string>
#include <vector>

namespace phantrix {
namespace split {

// The service name and the file the build installs beside the helper.
constexpr wchar_t kDriverServiceName[] = L"PhantrixSplitTunnel";
constexpr wchar_t kDriverFileName[] = L"phantrix_split_tunnel.sys";

// The policy as it arrives from the plugin.
struct Policy {
  bool enabled = false;
  bool include_mode = true;
  std::vector<std::wstring> apps;
};

class Controller {
 public:
  Controller() = default;
  ~Controller();

  Controller(const Controller&) = delete;
  Controller& operator=(const Controller&) = delete;

  // Records the policy and checks that it can be applied at all: the driver is
  // present and startable, the paths still exist, and the physical address that
  // exclude mode redirects to can be found.
  //
  // Called before the engine starts, so a machine that cannot honour the
  // policy refuses the connection instead of bringing a tunnel up and then
  // discovering it has no way to route around it.
  bool Prepare(const std::wstring& module_directory, const Policy& policy,
               std::string* error_code, std::string* error_message);

  // Applies the prepared policy to a connected tunnel.
  //
  // `tunnel_luid` is the Wintun adapter the engine is using. Called after the
  // engine reports its handshake, which is the first moment the adapter has an
  // address to redirect to.
  bool Apply(NET_LUID tunnel_luid, std::string* error_code,
             std::string* error_message);

  // Removes every filter and the include-mode route. Safe to call repeatedly.
  void Clear();

  // Drops every rule and releases the driver service. Called on helper exit.
  void Shutdown();

  bool prepared() const { return prepared_; }
  bool applied() const { return engine_ != nullptr; }

 private:
  bool EnsureDriver(const std::wstring& module_directory,
                    std::string* error_code, std::string* error_message);
  bool CapturePhysicalAddresses(std::string* error_code,
                                std::string* error_message);
  bool ReadTunnelAddresses(NET_LUID tunnel_luid, std::string* error_code,
                           std::string* error_message);

  bool BeginSession(std::string* error_code, std::string* error_message);
  bool AddRedirectFilters(const std::wstring& target_description,
                          std::string* error_code, std::string* error_message);
  bool AddBlockV6Filters(std::string* error_code, std::string* error_message);
  void RemoveIncludeRoute();

  bool prepared_ = false;
  bool driver_started_ = false;
  std::wstring module_directory_;
  Policy policy_;

  // Physical interface and its addresses, captured before the engine installs
  // its routes: once the tunnel is up, "best interface" answers with the
  // tunnel, which is the opposite of what exclude mode needs.
  bool have_physical_v4_ = false;
  bool have_physical_v6_ = false;
  IN_ADDR physical_v4_ = {};
  IN6_ADDR physical_v6_ = {};
  NET_LUID physical_luid_ = {};

  bool have_tunnel_v4_ = false;
  bool have_tunnel_v6_ = false;
  IN_ADDR tunnel_v4_ = {};
  IN6_ADDR tunnel_v6_ = {};
  NET_LUID tunnel_luid_ = {};

  // The dynamic WFP session. Closing it removes every object the session
  // added, which is the cleanup guarantee this feature relies on.
  HANDLE engine_ = nullptr;
  FWPM_SESSION0 session_ = {};

  bool include_route_v4_ = false;
  bool include_route_v6_ = false;
};

}  // namespace split
}  // namespace phantrix

#endif  // PHANTRIX_SPLIT_TUNNEL_H_
