# Plan: driverless split tunneling + Windows kill switch + settings UX (2026-11-15)

1. Settings UI (agent): split tunneling own section + toggle on settings page; wheel scroll over
   whole page; split page autosaves every change.
2. Split tunneling via bundled sing-box 1.14.4 (TUN + process_path rules), started by helper
   after OpenVPN handshake. Helper removes OpenVPN def1 routes from tunnel while split is on.
   Remove custom kernel driver from build/bundle; helper deletes legacy PhantrixSplitTunnel service.
3. Kill switch: helper installs persistent WFP filters (block all except loopback, tunnel iface,
   sing-box TUN iface, openvpn.exe, sing-box.exe, phantrix.exe, DHCP, LAN minus DNS).
   automatic: on while session active incl. drops; removed on user Disconnect / app exit.
   strict: lockdown, persists after Disconnect/app close/crash/reboot until connect or switched off.
   UI warning when picking strict. Unblock path launches helper `--release-firewall`.
4. Licences/notices for sing-box, fetch script with pinned hash, docs (BUILDING/SECURITY).
5. Verify: flutter analyze, flutter test, build windows; user live-tests on second PC.
