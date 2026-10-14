# Release-readiness evidence

Date: 2026-10-09. Environment: Windows 11, non-elevated user, Flutter 3.47.0 /
Dart 3.13.0, JDK 25 (Android Studio JBR), AGP 9.1.0, Visual Studio 2022.
Android 14 x86_64 emulator (`phantrix_test`); Xiaomi Redmi Note 10 Pro
(Android 13, API 33, arm64) for observational launch only.

**How to read this.** Each row states the environment, the method, the result,
and the remaining limitation. "Verified" means observed in this session, not
inherited from an earlier report. Anything not verified here is marked
accordingly — a green unit-test suite is not network evidence and is never
presented as such.

## Verdict

**Not releasable as a working VPN client.** The application builds, installs,
launches, validates, stores, fails honestly, and protects its key material as
documented — but no WireGuard handshake has ever been observed on any
platform, because no reachable peer exists in any available environment. Every
row below is the evidence for that sentence.

Two later events change parts of this picture and are recorded as addenda at
the bottom: an OpenVPN tunnel **was** established and verified on Windows
(2026-10-11), and the Android OpenVPN engine was removed for licence
compatibility (2026-10-13), leaving Android WireGuard-only.

## Evidence table

| # | Area | Environment / method | Result | Limitation |
| --- | --- | --- | --- | --- |
| 1 | Source analysis | `flutter analyze` (app), `dart analyze` (core, platform), `flutter analyze` (platform tests) | No issues in any package | Static analysis cannot see runtime behaviour |
| 2 | Automated tests | `dart test` (core), `flutter test` (platform), `flutter test` (app) from a clean checkout | **341 pass, 0 fail**: core 173, bridge 20, app 148 | Host-VM tests prove logic, not OS behaviour; POSIX mode test skips on Windows |
| 3 | Clean builds | `flutter clean` then analyze + tests + all release builds from the same tree, 2026-10-09 | Analyze clean; 148 app tests pass; 3 split APKs (18.0/20.8/22.4 MB) + AAB (52.9 MB) + Windows bundle (27.8 MB) all rebuilt from clean; 22/22 artifact checks pass on the fresh DLL | Linux/Apple cannot build on this host (CI / Mac required). One mid-run source edit broke an AAB attempt — itself evidence the pipeline builds what is there, not a cache |
| 4 | Installation | `adb install` of release APK on emulator (x86_64) and observational launch on physical arm64 phone | Installs and launches on both; renders correctly on 1080×2400 hardware | Release artifacts are debug-signed — installable, not publishable |
| 5 | Application startup | Cold start on emulator + physical device; seeded-store experiment via `run-as` | Starts to notice/dashboard as the stored flags dictate; seeded settings applied (dark dashboard, no notice) | Two debug-build stalls observed mid-session were not root-caused (see notes) |
| 6 | Real tunnel establishment | — | **Not verified.** No peer available | Requires the procedure in `docs/TEST_PEER_SETUP.md` |
| 7 | Successful handshake | — | **Not verified.** No peer available | Server-side `wg show` is the defined evidence; never observed |
| 8 | Public-IP verification | Code path reviewed; `LeakCheck` compares pre/post baseline and fails closed on unchanged address | Logic-tested on host (incl. captive-portal and stale-handshake cases) | Never run against a live tunnel |
| 9 | DNS and IPv6 verification | Mapper logic reviewed + unit-tested (route construction, IPv6 stripping, DNS modes) | Android/Windows/Linux enforce per the matrix in SECURITY.md §6 | Never observed live; Windows does not enforce IPv6 block (reported, known gap) |
| 10 | Kill-switch tests | Audit of every backend + live `Settings.Secure` read/write on API 34 | **No backend blocks traffic itself**; Android reports the genuine OS lockdown state live; strict is refused out loud | Lockdown enforcement itself (blocking packets) never tested — needs a tunnel + failure |
| 11 | Windows runtime | Built app launched; `%LOCALAPPDATA%\Phantrix` ACL read with `icacls`; `windows_check.ps1` executed; 22 artifact checks on the built DLL | User+SYSTEM-only DACL confirmed; diagnostic reports missing backend + non-elevated session honestly | No tunnel run (no WireGuard for Windows, no Administrator) |
| 12 | Linux runtime | Workflow validated with actionlint; C++ changes reviewed (no Linux toolchain on this host) | CI compiles, links, exports; guards hold | Never run on a live system |
| 13 | Android runtime | 15/15 engine tests + 4/4 app tests on emulator, re-verified 2026-10-09; release launch on physical phone; uninstall removes all data | Engine, UI honesty, persistence read, clean uninstall all observed | No handshake, no traffic, no physical-device tunnel run |
| 14 | Apple compilation / signing / runtime | Source audit only | Complete source, correct Keychain/extension lifecycle on paper; stop path deletes the keychain item | Never compiled, never signed, never run. Requires Xcode + Mac + Developer account |
| 15 | Artifact signing | `apksigner verify --print-certs` on the release APK; `aapt dump badging` | v2-signed, `CN=Android Debug`; package `dev.phantrix.phantrix`, minSdk 24, exact permission set | Debug-signed: installable, not publishable. No maintainer key supplied |

## Notes on the two debug-build stalls

During this session the debug build twice failed to reach its first frame on
a manual emulator launch (blank splash, 0% CPU, VM service unresponsive), and
once rendered but ignored `input tap`. Investigation established:

- The installed APK was current (all new strings present in `kernel_blob.bin`).
- Channel names match on both sides; decode of stored settings verified on host.
- The "seed ignored" observation was a malformed seed file (double-escaped
  JSON from the seeding pipeline): the app correctly fell back to defaults.
  Re-seeding with valid JSON produced the seeded dashboard, proving the
  persistence read path end to end on a real launch.
- `input tap` was later shown to reach neither the app nor system UI on this
  headless emulator, so the "dead input" observation is an environment
  artifact, not an app finding.
- The splash stalls were never reproduced after a `pm clear`, and every
  launch since — release (multiple), debug under `integration_test` (+4),
  debug manual with valid seed — has succeeded.

Because an unbounded startup wait would turn any recurrence into a permanently
blank app, `AppScope.bootstrap` now bounds the platform directory lookup (5 s
per attempt, one retry) and reports every fallback instead of hanging. Two
regression tests pin the bound. The underlying stall itself remains
unexplained and is recorded here as such — it is not claimed as fixed.

## Addendum 2026-10-10: OpenVPN backend verification round

A full OpenVPN verification round ran after this table and is reported in
`docs/OPENVPN_BACKEND_VERIFICATION.md` (engines, licences, live runs,
failure behaviour, DNS/IPv6/kill-switch posture, obligations, blockers).
Headline results, all command-backed:

- Dart: analyze clean, app suite **190 pass / 1 skip** (182 prior + 8 new
  this session: 6 failure-behaviour tests covering disconnect-mid-attempt,
  engine death mid-attempt, server switching, startTunnel rejection, engine
  auth failure, and reconnect timeout; plus 2 handshake-timestamp-ordering
  tests), core 180, platform 20; release APK and Windows bundle build.
- Android native: AAR checksum re-verified, 51/51 Kotlin tests, debug APK
  with merged manifest + native libs inspected; a live run found and fixed
  a fatal main-thread crash in engine-event delivery plus an overclaiming
  stats label.
- Windows native: bundle hashes re-verified, `openvpn.exe --version` runs
  unelevated (2.6.17/OpenSSL 3.6.0), config-error and unreachable-server
  exits classified on the real binary, 43/43 artifact checks.
- **No OpenVPN handshake has been observed on any platform.** Live Android
  runs reach "Negotiating with the server" and end in honest
  `tunnel.timeout`; transport (TCP 443) to the relays is proven reachable
  from the emulator, client certificates are valid, and no credentials are
  required — so the failures sit at the TLS/server layer, still being
  isolated. The manual-launch splash stall noted above recurred once during
  this round (integration-test launches render fine); the stall itself is
  still unexplained.
- Release blockers are listed in the verification report §9; the first is
  the missing handshake, followed by `libovpn3.so` conveyed without a
  declared licence, the missing Corresponding Source offer for the AAR,
  the unresolved GPL-2.0-only/or-later disagreement, and the open wintun
  redistribution reading.

## What is needed to close the open rows

1. **A WireGuard peer** (rows 6–10, parts of 11–13): one Linux host,
   `docs/TEST_PEER_SETUP.md`, ~30 minutes. External input required: a machine
   and a network the operator controls. No credentials are needed from anyone
   — the procedure generates throwaway keys.
2. **An Android upload key** (rows 4, 15): generated by the maintainer,
   referenced from `android/key.properties` (git-ignored). Documented in
   README §"Signing the Android release".
3. **Apple build environment** (row 14): Xcode, a Mac, an Apple Developer
   account with Network Extension entitlement.
4. **Elevated Windows host with WireGuard for Windows** (row 11) and **a Linux
   host with sudo** (row 12): for the runtime halves of those rows.

## Addendum 2026-10-11: a completed, verified OpenVPN tunnel on Windows

Observed and captured, superseding the "no OpenVPN handshake has been observed
on any platform" line in the 2026-10-10 addendum above:

- `Initialization Sequence Completed` on adapter 44 `Phantrix` (`10.211.1.37`),
  routes installed through `10.211.1.38`.
- Exit address changed from `203.0.113.5` to `59.130.24.201` — the relay's
  own address — confirmed by two independent means (a fresh-process `curl`
  watcher and a direct read while the adapter was Up).
- Held connected for 6.5+ minutes with the exit address still `59.130.24.201`.

Two fixes were required to get there (a pooled-socket bug in
`lib/vpn/leak_check.dart` that always read the pre-tunnel address, and the
`walkable` classification in `lib/vpn/connection_controller.dart`).
Full write-up: `docs/evidence/openvpn/WINDOWS_VERIFICATION_2026-10-11.md`;
raw capture: `docs/evidence/openvpn/live-capture-2026-10-11-honest.log`.

This is an **OpenVPN** tunnel. No WireGuard handshake has still never been
observed anywhere; rows 6–7 above stand unchanged.

## Addendum 2026-10-13: the Android OpenVPN engine was removed

The Android `icsopenvpn` AAR and the `de.blinkt.openvpn` bridge were deleted
from this checkout because GPL-2.0-only code cannot be combined with
GPL-3.0-only code in one distributed work. Consequences for the rows above:

- Android loses its OpenVPN backend and is **WireGuard-only**. The OpenVPN
  engine claims in the 2026-10-10 addendum describe work that is no longer in
  this tree and must not be read as a capability of a current Android build.
- The licence blockers that depended on the AAR (missing corresponding source,
  `libovpn3.so` licence, the GPL-2.0-only vs or-later disagreement) are closed
  by removal, not by resolution. `docs/LICENSING_AUDIT.md` carries the current
  verdict.
- The Windows OpenVPN backend is unaffected and is byte-identical to its
  state before the removal.
- The test totals drop with the deleted Kotlin tests; re-run the suites for
  current numbers rather than citing the ones above.

## Addendum 2026-10-13: live tunnel re-verified on this checkout

With the Android engine removed and the Windows bundle rebuilt from this
tree (`flutter build windows`, then `tools/check_windows_build.ps1
-RequireOpenVpn`: 48 checks, 0 failures), the bundled Windows engine was run
live against VPN Gate relays on this machine, three times via a UAC-consented
elevated harness:

- **13:30:33 and 14:04:31: `Initialization Sequence Completed`** against the
  `opengw.net` relay `182.171.136.48:1346` (TCP), twice, from profiles
  emitted minutes earlier by `dart run tools/diagnose_windows.dart --emit`.
  Pushed `10.211.1.x` addresses; the engine installed its full-tunnel `/1`
  routes both times and negotiated `AES-128-CBC/SHA1` on the data channel.
- The raw engine log of the second run is committed as
  `docs/evidence/openvpn/live-tunnel-2026-10-13-engine.log`; the first run's
  log was overwritten on the same profile name, and the 13:29 attempt's log
  (US relay `104.28.211.105:443`) shows that relay never answered a TCP
  connect from this network.
- After every run the machine was verified back at its pre-run state: 0
  `openvpn` processes, 0 Wintun adapters, 0 tunnel routes, per-interface DNS
  unchanged, exit address `154.254.22.161` again.

Not observed in this session: a live exit-address snapshot *while* the
tunnel was up - the 2026-10-11 addendum above remains the evidence for that.
The adapter-probe harness cannot produce it (wintun removes an adapter when
its creating handle closes, and the probe creates the adapter, so a tunnel
driven through the probe collapses when the probe returns);
`tools/windows_live_tunnel.ps1` - procedure C in
`WINDOWS_LIVE_VERIFICATION.md` - launches the engine the way the helper
does, which keeps the tunnel up for that capture. It needs one UAC consent
and was not completed in this session.
