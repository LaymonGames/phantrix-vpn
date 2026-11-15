# Project state (Phantrix)

Flutter VPN client. Windows: unelevated app + elevated helper `phantrix_ovpn_helper.exe`
(packages/phantrix_platform/windows) running bundled `openvpn.exe` + wintun, and for split
tunnelling bundled `sing-box.exe` (tools/fetch_singbox_bundle.ps1). Android: VpnService.

## Status (2026-11-15)
- Split tunneling: driverless (sing-box). Builds; NOT live-tested yet.
- Kill switch: Windows only, WFP rules in helper. Builds; NOT live-tested yet.
- Settings UI: split tunneling own section, toggle, autosave, full-page wheel scroll.
- Old test-signed driver build output may remain untracked at
  packages/phantrix_platform/windows/driver/phantrix_split_tunnel/*.sys (ignored, unused).
