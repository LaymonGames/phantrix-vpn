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
