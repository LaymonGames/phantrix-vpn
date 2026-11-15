// The Windows kill switch: firewall rules that stop traffic leaving outside the
// tunnel.
//
// ## Mechanism
//
// Ordinary user-mode Windows Filtering Platform filters, added by the elevated
// helper. No driver is involved: blocking and permitting are built-in WFP
// actions, only redirection would need a callout.
//
// Every object lives under one provider and one sublayer, so the whole set can
// be found and removed as a unit. The filters are *persistent*: they outlive the
// helper process. That is what lets the kill switch keep blocking while a
// dropped tunnel is being reconnected, and lets strict mode keep blocking after
// the app is closed.
//
// ## What stays allowed
//
//   * loopback;
//   * anything on the OpenVPN tunnel adapter and the split-tunnel router's
//     adapter;
//   * the engine (openvpn.exe), the split-tunnel router (sing-box.exe) and the
//     Phantrix app itself, so a new connection can always be made;
//   * DHCP, so the physical network keeps its address;
//   * the local network (private and link-local ranges), except DNS;
//   * DNS to any server only while a connection is being set up, so the
//     engine can resolve the VPN server's name.
//
// ## Modes
//
//   automatic: rules exist from the start of a connection until the user
//              disconnects or the app exits, including while a dropped
//              connection waits to be reconnected.
//   strict:    rules also stay after the user disconnects, after the app exits
//              and across reboots, until a connection replaces them or the kill
//              switch is turned off.

#ifndef PHANTRIX_KILL_SWITCH_H_
#define PHANTRIX_KILL_SWITCH_H_

#include <winsock2.h>
#include <windows.h>
#include <netioapi.h>

#include <string>
#include <vector>

namespace phantrix {
namespace firewall {

enum class Mode { kOff, kAutomatic, kStrict };

Mode ParseMode(const std::string& text);
const char* ModeName(Mode mode);

// The marker file the unelevated app reads to learn that blocking rules are in
// place: `%ProgramData%\Phantrix\kill-switch` holding the mode name.
std::wstring MarkerPath();

// `%ProgramData%\Phantrix`, created or re-secured so only Administrators and
// SYSTEM can write to it. Empty when it cannot be trusted (a reparse point,
// or owned by someone else); callers then write nothing there.
std::wstring StateDirectory();

// A subdirectory of [StateDirectory] with the same protection.
std::wstring StateSubdirectory(const std::wstring& name);

class KillSwitch {
 public:
  KillSwitch() = default;

  // Installs the rules, replacing any earlier set in one transaction so there
  // is no moment without them. `apps` are executables always permitted; the
  // first must be the VPN engine, whose permit is mandatory.
  bool Engage(Mode mode, const std::vector<std::wstring>& apps,
              std::string* error_code, std::string* error_message);

  // Permits an adapter (the tunnel, the router) and reinstalls the set.
  bool PermitInterface(NET_LUID luid, std::string* error_code,
                       std::string* error_message);
  // Withdraws an adapter permit, e.g. when the router stops.
  void ForgetInterface(NET_LUID luid);

  // While true, DNS to any server is permitted so the engine can resolve the
  // VPN server. Turned off once the tunnel is up.
  bool SetSetupDns(bool allowed, std::string* error_code,
                   std::string* error_message);

  // Keeps blocking after this process exits, with only the rules that need no
  // running tunnel: adapter permits and the connecting-time DNS permit go.
  bool KeepAfterExit(std::string* error_code, std::string* error_message);

  // Removes the rules and forgets the mode, so nothing later in this
  // process can reinstall them.
  bool Disengage(std::string* error_message);

  // Copies the helper to `%ProgramData%\Phantrix\phantrix-unblock.exe`, so
  // strict rules can still be lifted (`phantrix-unblock.exe
  // --release-firewall`, as administrator) if the app folder is deleted.
  static void InstallRecoveryHelper(const std::wstring& helper_path);

  bool engaged() const { return mode_ != Mode::kOff; }
  Mode mode() const { return mode_; }

  // Removes every Phantrix kill-switch object and the marker. Safe when there
  // are none.
  static bool Release(std::string* error_message);

 private:
  bool Rebuild(std::string* error_code, std::string* error_message);

  Mode mode_ = Mode::kOff;
  std::vector<std::wstring> apps_;
  std::vector<NET_LUID> interfaces_;
  bool setup_dns_ = false;
};

}  // namespace firewall
}  // namespace phantrix

#endif  // PHANTRIX_KILL_SWITCH_H_
