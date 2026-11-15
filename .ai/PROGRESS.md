# Progress
- 2026-11-15: Diagnosed split.driver_failed = test-signed driver. Kill switch audit: never built
  (windows plugin reports killSwitch=false; startTunnel ignores it).
- 2026-11-15: Split tunnel reimplemented on sing-box 1.14.4 (helper child process, config in
  session dir router.json, adapter "Phantrix Split", process_path_regex case-insensitive,
  OpenVPN def1 routes removed from tunnel while router runs + metric-32000 0/0 for bound
  sockets, restored on Clear). Legacy PhantrixSplitTunnel driver service deleted by helper.
- 2026-11-15: Kill switch: persistent WFP filters, provider {3f6b2c71-8d4e-4a19-b26c-5e910d7a4001},
  filter keys pooled (last byte = index). Marker %ProgramData%\Phantrix\kill-switch.
  kStart fields: profile,status,log,split,mode,killSwitch,apps... kStop field "hold".
  Plugin: killSwitchState / releaseKillSwitch methods; failure teardown holds if handshaked.
  Helper `--release-firewall` removes rules. Not live-tested (shell not elevated).
- 2026-11-15: Kill switch Flutter UI: Settings row hints per mode (Off/Automatic/Strict), Strict
  confirm dialog (cancel keeps mode); Off or Strict->Automatic while blocking calls
  releaseKillSwitch (snackbar on Err); refreshKillSwitch after every change (callbacks threaded
  destinations -> SettingsScreen -> ConnectionPanel). Home: _KillSwitchCard (home_kill_switch_card.dart)
  when view.killSwitchBlocking, strict/automatic text, Unblock with progress + inline error.
  Diagnostics kill row: mode value, Off=warning, firewall-rule detail. test/kill_switch_ui_test.dart (8).
  licenses_test OpenVPN-notice failure pre-existing (sing-box attribution file), not from this work.
- 2026-11-15: Commit 165ab11 "now split tunneling works everywhere mostly".
- 2026-11-15: Review fixes (native): stop/handshake race (stoppingEngine before lock, recheck,
  KillSwitch::Disengage), automatic hold released on Disconnect/app exit via elevated
  --release-firewall, DNS re-allowed on engine "reconnecting", router started before route swap
  and routes restored before router stops, sing-box default_interface pinned to physical alias,
  %ProgramData%\Phantrix created with admin-only protected DACL + reparse/owner checks (was an
  arbitrary-file-write primitive), router config/log moved there, recovery helper copy
  phantrix-unblock.exe for strict mode, handle-list inheritance, job assignment mandatory.
- 2026-11-15: Redesign: accent-driven theme (lib/theme/vg_accent.dart: VgAccent presets, per-theme
  contrast-safe tones, VgDecor ThemeExtension), working System/Light/Dark, accent picker
  (settings/accent_picker.dart), bundled Inter font, status headline + protection summary on
  home, hero card with state wash, new orb face, page titles on desktop, canvas glow.
  Contrast test covers all presets + hues in both themes. 526 tests pass.
- 2026-11-15: Windows release built + smoke-launched. Linux release NOT built: no WSL/Docker here.
- 2026-11-15: Home content vertically centred when short. Settings sections all stay expanded (folding removed on request). Split picker scrolls back to the top after a tick. Split router: strict_route off (Windows strict_route blocked port 53 on the tunnel/physical interface, which killed all DNS). [SUPERSEDED 2026-11-15: kill switch now installed with split too.] Windows --release rebuilt. Linux needs one Windows restart for WSL, then tools\build_linux_wsl.ps1.
- 2026-11-15: Stop is immediate: Engine::Stop sends CTRL_BREAK then kills OpenVPN after 250 ms (was 10 s connected / 2 s dialing, spent on explicit-exit-notify "negotiating"). Applies to disconnect, cancel and server switch.
- 2026-11-15: Split tunneling "connected but browsers can't search": router log showed every IPv6 dial failing ("unreachable network") because neither the tunnel nor Ethernet has IPv6, while the router adapter advertised it; browsers got AAAA records, the router accepted the TCP connection, then dropped it, so no IPv4 fallback. Fix: IPv6 offered only when tunnel AND physical both have it (PhysicalHasIpv6); otherwise dns.strategy ipv4_only and first rule {"ip_version":6,"action":"reject"}. Config validated with sing-box 1.14.4 `check`. Windows --release rebuilt; analyze clean; 528 tests pass. NOT live-tested on a connection yet.
- 2026-11-15: Kill switch did not block on Windows. Causes: (1) helper forced kill switch Off whenever a split policy was active (user had split on); (2) strict rules were only installed at connect, so choosing strict while disconnected installed nothing. Fixes: split exclusion removed (router egress is sing-box.exe, a permitted app; router adapter permitted after Apply); new elevated `phantrix_ovpn_helper.exe --engage-firewall --app <exe>` installs strict rules with no tunnel (Engage + KeepAfterExit + recovery helper); plugin method `engageKillSwitch` (worker job, skipped while a session runs or marker already strict); Dart PhantrixPlatform.engageKillSwitch, ConnectionController.engageStrictKillSwitch (called when strict is confirmed in settings and after every user teardown that ends disconnected); `killSwitchSplitPaused` note + strings removed. 530 tests pass, analyze clean. Native compiled; release install step failed only because phantrix.exe was running. NOT live-tested.
- 2026-11-15: Live kill-switch change while connected. New pipe msg kKillSwitch(14) plugin->helper; helper rebuilds rules in place (Disengage for off; Engage + permit adapter/router + DNS off past handshake otherwise). Plugin method setKillSwitchMode; Dart PhantrixPlatform.setKillSwitchMode; ConnectionController engage/release call _applyKillSwitchLive when connected; panel also calls engage for Off->Automatic. Analyze clean, 531 tests, Windows release built. NOT live-tested. Still open: strict-mode connect problems and app-exit orphan processes were only partly addressed by earlier (opencode) edits; verify live.
- 2026-11-15: App exit now lifts kill switch in every mode (plugin dtor: TeardownOpenVpn(false) + elevated release if marker remains). Mode changes verified against marker (_verifyKillSwitch); mismatch/denied UAC => Err => settings revert. Live change while connected uses elevated helper (no new UAC). Linux script unchanged (Windows-only + Dart). 531 tests, Windows release built. Not live-tested.
