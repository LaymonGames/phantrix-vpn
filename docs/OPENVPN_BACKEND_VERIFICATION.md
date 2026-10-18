# OpenVPN backend — verification report

Status of the OpenVPN work in this repository: what was built, what was
**verified**, and what remains **NOT RUN**. Every claim below names the
command or artifact it rests on; nothing here is asserted that was not
executed.

> **Status change, 2026-10-13: the Android OpenVPN engine was removed.**
> The `icsopenvpn` AAR, the `localmaven/` directory, the `de.blinkt.openvpn`
> bridge (`OpenVpn*.kt`), the Android E2E driver and its licence files are no
> longer in this tree. They were deleted because GPL-2.0-only code cannot be
> combined with GPL-3.0-only code in one distributed work
> (`docs/LICENSING_AUDIT.md`). Sections marked **[historical]** below describe
> that removed engine: they record what was observed at the time and must not
> be read as a capability of a current Android build. The **Windows** backend is
> untouched by the removal and its content is current. Where this report
> contradicts `docs/evidence/openvpn/WINDOWS_VERIFICATION_2026-10-11.md`, the
> evidence file is newer and wins.

> **Status change, 2026-10-16: the WireGuard backend was removed and the app
> became OpenVPN-only.** The Android `VpnService` and its WireGuard engine, the
> Windows `wireguard.exe` path and the protocol choice in the app are gone. The
> app now declines a WireGuard server by name instead of offering one. Where
> this report says WireGuard "remains the other engine", read that as a fact
> about the time of writing: the only engine any current build can run is
> OpenVPN on Windows.

Environment used for all results: Windows 11, Flutter 3.47.0 / Dart 3.13.0
(`C:\FlutterSDK`), JDK 25 (`C:\Program Files\Android\Android Studio\jbr`),
Gradle 9.3.1 via `android/gradlew.bat`, Android SDK with adb, VS Community
2026. The session is **not elevated**.

## 1. Engine choice and licensing

The engine is the official OpenVPN implementation, not a reimplementation:

| Platform | Engine | Licence | How it ships |
| --- | --- | --- | --- |
| Android | **None.** The `icsopenvpn` engine described in this report was removed on 2026-10-13 for licence incompatibility (GPL-2.0-only cannot combine with GPL-3.0), and the WireGuard engine that replaced it was removed on 2026-10-16 | — | Not shipped. Android has no engine, and the app declines every relay with an explanation |
| Windows | Official OpenVPN 2.6 community binaries | GPL-2.0 | Separate elevated helper process (`phantrix_ovpn_helper.exe`); downloaded and verified by `tools/fetch_openvpn_bundle.ps1` |
| Windows tunnel device | wintun (`wintun.dll`, WireGuard LLC) | wintun prebuilt-binaries licence | Same fetch script |

WireGuard was the other engine at the time of writing
(`com.wireguard.android:tunnel` on Android, the official WireGuard for
Windows service on Windows). Both of those paths were removed on
2026-10-16; the Linux and Apple sources still drive WireGuard, and the
domain library still parses it.

**[historical] Why the Android engine was removed.** The adjacent sidecar
copied from upstream tag `v0.7.55` (sha256 `2ff8cdba…`) said
*"either version 2 of the License, or (at your option) any later version"*
and stated that using the `de.blinkt.openvpn` class hierarchy creates a
derivative work. However, the AAR's own `assets/full_licenses.html` said GPL
version 2 without an explicit later-version grant; F-Droid metadata for version `0.7.68` (added 5 October 2026) also says
`GPL-2.0-only`. These are not the same
artifact/version, so none alone resolved the exact Mysterium AAR terms.
Rather than ship an unresolved GPL-2/GPL-3 combination, the engine and its
bridge were removed. The current verdict is in `docs/LICENSING_AUDIT.md`.

## 1b. Distribution obligations, per platform — and the open questions

This section states what the texts say and what this project does about it.
It is engineering provenance, not legal advice; every open question is
flagged rather than answered by guesswork.

The project's independently authored code is intended to be GPL-3.0-only.
`LICENSE` is the unmodified standard GPLv3 text, and `COPYRIGHT` limits that
project grant to original code that is not derived from third-party code. The
repository also contains separately licensed and adapted components, so neither
the root licence text nor the in-app project row should be read as clearing the
whole checkout for blanket GPL-3.0-only distribution without reading
`THIRD_PARTY_LICENSES.md`.

**Android APK** conveys, among others:

- `libwg-go.so` via `com.wireguard.android:tunnel` 1.0.20260102:
  Apache-2.0 (licence read from the published POM; sha256 pinned in
  `verification-metadata.xml`), compatible with GPLv3 distribution.
- [historical] The Android build used to carry Kotlin glue adapted from
  `openvpn_dart` (MIT, © BlockDev AG 2023). That glue went with the Android
  OpenVPN engine. The `openvpn_dart` attribution that remains applies to the
  Windows backend; see `THIRD_PARTY_LICENSES.md`.
- [historical] Prior to 2026-10-13 the APK also conveyed `libopenvpn.so`,
  `libovpnexec.so` and `libovpn3.so` from the vendored AAR. Those are gone
  with the engine.

**Windows installer** conveys: `openvpn.exe` plus its runtime DLLs —
GPL-2.0 **without** an "or later" grant (bundle `LICENSE.txt`: "OpenVPN is
distributed under the GPL license version 2", line 20; "OpenVPN, LZO, and
the TAP-Win32 distributions are licensed under the GPL version 2", line
254) — run as a **separate process**, which is aggregation rather than
linking (no shared address space, fixed argv, file-based handoff only);
`libpkcs11-helper-1.dll`, whose upstream `COPYING` offers a choice of
"GPL Version 2, or the BSD license" (verified) — either choice is
aggregation-safe in this shape; `wintun.dll` (see Q3 below);
`vcruntime140.dll` (Microsoft Visual C++ Redistributable terms); and the
helper + plugin built from GPL-3.0 source in this repository. The bundle
binaries are **not** in git (only `bundle/.gitignore` is tracked), so
repository distribution does not convey them — the locally built installer
does.

The repository includes an attribution inventory and the
licence texts it needs, but compliance is not yet established for every
distributed artifact. The Windows Wintun
redistribution condition below remains open; do not treat the current inventory
as release clearance.

Open compliance questions:

1. **[closed by removal] Corresponding Source for the vendored AAR.** The AAR
   was object code conveyed both in git and in the APK with no source in this
   repository and no written offer. Removing the AAR removes this question
   rather than answering it.
2. **[closed by removal] The exact Android AAR licence grant.** The upstream
   v0.7.55 sidecar and the AAR's own embedded notice differed on whether later
   GPL versions were permitted. The engine was removed instead of resolving
   the conflict.
3. **wintun redistribution.** §3(d) of the Prebuilt Binaries License
   permits redistribution when the unmodified DLL is shipped alongside
   software that uses it exclusively through the Permitted API. Phantrix's
   code does not call Wintun directly; the OpenVPN process is the API consumer.
   Confirm the exact bundled OpenVPN integration satisfies that condition and
   keep the DLL paired with OpenVPN; do not distribute it independently.
   project's distribution is an open reading — recorded, not assumed.

## 2. Dart layer (Phases 1 and 4)

Numbers below were re-measured on 2026-10-13, after the Android OpenVPN
engine was removed:

| Check | Result |
| --- | --- |
| `flutter analyze --no-pub` (root) | **No issues found!** |
| `flutter test` (app package) | **269 passed, 1 skipped, 0 failed** |
| `packages/phantrix_core`: `flutter test` | **184 passed** |
| `packages/phantrix_platform`: `flutter test` | **21 passed** |
| `:phantrix_platform:testDebugUnitTest` (Kotlin) | **[historical]** 51/51 green while the OpenVPN bridge existed; those tests were deleted with it |
| `dart run tools/generate_third_party_notices.dart` | **94 entries, 84 bundled licence texts**; deterministic (byte-identical re-runs) |
| `dart analyze tools/generate_third_party_notices.dart` | **No issues found!** |
| `flutter build windows` | **Built** `build\windows\x64\runner\Release\phantrix.exe` with `openvpn.exe`, `wintun.dll`, `phantrix_ovpn_helper.exe`, `phantrix_platform_plugin.dll`, `LICENSE.txt` in the bundle |

State-machine and protocol work: consent-first connection, bounded
`connectTimeout`, explicit `permissionRequired`/`disconnecting` states,
protocol-aware rejection of incompatible servers with actionable errors, one
authoritative state machine, real elapsed-time/traffic stats, and the
in-app licenses page are all covered by the tests above.

Note: `dart format` was deliberately **not** run on this repository. The
code is hand-indented with tabs and the CI format gate
(`.github/workflows/verify.yml`) already fails at baseline for ~90 of ~100
files; reformatting would have rewritten nearly every file and buried the
real changes. This is reported rather than "fixed".

## 3. Android **[historical — the engine described here no longer exists in this tree]**

Everything in this section records work done while `icsopenvpn` and the
`OpenVpn*.kt` bridge were in the repository. They were removed on 2026-10-13
for licence incompatibility (§1). The evidence is kept because it is real and
because it explains the defects found and fixed in code that still exists
(§5). It is **not** a description of a current Android build: an Android build
from this tree has no OpenVPN engine and will refuse an OpenVPN server with an
explanation.

| Check | Result (at the time) |
| --- | --- |
| AAR checksum | **Verified**: sha256 `3540c8579b0056baac517cb6c930d9d9fb19cbbdf6216e4353fce5513aee50f6` |
| `:phantrix_platform:compileDebugKotlin` | **BUILD SUCCESSFUL** |
| `:phantrix_platform:compileReleaseKotlin` | **BUILD SUCCESSFUL** |
| `:phantrix_platform:testDebugUnitTest` | **51/51 green** (deny-list 16, status mapping 17, text redaction 9, request parser 9) |
| `:app:assembleDebug` | **BUILD SUCCESSFUL** (106.4 MB APK) |
| Merged manifest of that APK | `de.blinkt.openvpn.core.OpenVPNService` present with `BIND_VPN_SERVICE`, `foregroundServiceType=specialUse`, `PROPERTY_SPECIAL_USE_FGS_SUBTYPE=vpn`; POST_NOTIFICATIONS/FGS permissions present; `extractNativeLibs=true` |
| Native libs in that APK | `libovpnexec.so`, `libopenvpn.so` (+ WireGuard's `libwg-go.so`) for arm64-v8a, armeabi-v7a, x86_64 |
| Dependency verification | `android/gradle/verification-metadata.xml` extended by exactly the two intended components (icsopenvpn aar+pom, org.json for the JVM tests) |
| Live run | `integration_test/openvpn_live_tunnel_test.dart` on the `phantrix_test` emulator (API 34) with the consent dialog approved by `tools/run_openvpn_e2e.ps1`; evidence in `docs/evidence/openvpn/` — **both the test and the driver have since been deleted with the engine** |

**The gate run.** A later run with the fixed build produced, on its second
attempt, a fully verified session against relay `222.117.16.150`
(South Korea, the app's own top pick that minute):

- engine `Starting openvpn` 10:19:34 → `handshaked` with a timestamp →
  verification probed the exit IP → `222.117.16.150`, different from the
  pre-connection address → **connected**;
- live session panel: `Connected for`, `Downloaded 8.3 KB`, `Uploaded
  8.6 KB`, `Public IP 222.117.16.150`, `Protocol OpenVPN`, `IPv6 Blocked` —
  engine byte counters proving traffic crossed the tunnel, plus an
  independent exit-IP change proving it egressed at the relay;
- user disconnect → engine `Exiting` 10:19:53 → orb `Disconnected`, session
  cleared, temporary profile removed (watchdog samples show the `.vp`
  present during the attempt and gone after).

That is a real handshake and real tunnel traffic on Android, with a clean
disconnect and honest failures everywhere else in the same run (two
timeouts, three tapped-but-dead relays, one stale error card — itself fixed
afterwards, §5). The functional acceptance gate **passes on Android**.

**Confirmed on real hardware.** The same result was reproduced on the
physical device (Xiaomi M2101K6G / Redmi Note 10 Pro, Android 13, MIUI),
which is the machine whose red error started this round. First attempt:
`connected=true`, *"Connected via 60.119.0.51, which is different from the
address used before connecting"*, session panel `Downloaded 104.7 KB` /
`Uploaded 105.0 KB` / `Public IP 60.119.0.51` / `Protocol OpenVPN`, then a
clean disconnect back to `Disconnected`. MIUI accepted the install
(`INSTALL_FAILED_USER_RESTRICTED` did not recur — the toggle that caused it
was cleared on the device), and the OS VPN consent was already granted from
an earlier install, so no dialog appeared: on a phone that is normal, not a
defect. The two candidate causes of the reported red card are therefore both
closed — the route-installation race (§5 item 7) on the product side, and
the capabilities parse crash (§5 item 6) on the Windows side.

Windows remains blocked on elevation (procedure B), so the gate as a whole
— both platforms — does **not** pass, and there is no UI redesign in this
work.

A later attempt reached one layer deeper and is recorded exactly: handshake
observed and fresh, but *"no external address service could be reached, so
the connection could not be verified"* (`leak.unverified`). That outcome
means the exit-IP probe found neither the direct address (which would have
been the same-IP leak refusal) nor a relayed one — consistent with routes
installed but a relay that forwards nothing, though a racing route
installation cannot be excluded from that sample. The per-attempt network
snapshots added to the driver afterwards exist to separate those two.

The country survey (same run) tapped the Japan card (58 servers), the
United States card (2 servers) and the South Korea card (27 servers) with
the tapped card recorded verbatim per attempt; Germany, France and
Singapore were not offered by the feed. No country connected — every
attempt ended in an honest failure state with the dashboard usable. The
survey completed end to end, which also validates the bounded-pump fix
(the previous survey died in a `pumpAndSettle` that never settles on the
ticking home screen).

A later control run (pre-fix build, fresh emulator) went further three times
in a row: the engine reported its `handshaked` stage and the app answered
`leak.unverified` with *"the server has not completed a handshake"* — the
exact signature of the timestamp split (§5 item 5). Three engine-completed
handshakes, three app-side discards. That run is what isolated the defect;
the fixed build is under test at the time of writing.

**What it did not prove — and what the layers since isolated.** A completed OpenVPN handshake, and therefore a public-IP change, DNS behaviour, and live traffic counters, were **not observed through the app**: every selected volunteer relay either never answered (timeouts) or, once, completed the engine handshake while the app discarded its timestamp (§5 item 5) and reported `leak.unverified`. Isolating by layer:

- **Transport**: TCP 443 to four current relays is reachable from the
  emulator (`nc -w 8`, exit 0 on all four) — not a network block.
- **Profile shape**: a feed config plus the serializer's two appended lines
  completes TLS against **8/8 sampled live relays** (see §4: Windows
  `--dev null` probes, all `Initialization Sequence Completed`) — not a
  profile/cipher defect. The relays push minimal options
  (`PUSH_REPLY,ping 3,ping-restart 10` — no routes, no DNS), so local
  `redirect-gateway def1` is load-bearing for the full tunnel, and DNS
  falls back to pre-existing resolvers (§10).
- **Client credentials**: inline client certificates in 20/20 sampled rows
  are time-valid (2013–2037); no row requires `auth-user-pass` — not a
  credential or expiry defect.
- **Remaining suspects**: individual relay liveness (volunteers die
  constantly — confirmed live in §5 item 10, where the top three
  ranked relays were all unreachable from the same network an hour
  after the feed published them; the app used to bet the whole
  attempt on that one dead pick, and now walks the ranking), and —
  now fixed — the timestamp split that killed the one completed
  handshake.
- **The app's actual picks are not the feed's first rows.** Ranking the
  live feed with the app's own `ServerSelector` (temporary diagnosis test,
  since removed) shows the top picks are low-ping residential relays on
  odd high ports (e.g. `133.32.135.174:6804/udp`,
  `122.133.152.245:1783/udp`, `42.146.135.174:1570/tcp` — scores ~72.7),
  not the `:443` rows also probed. Those picks are probed individually
  below; liveness there is still open.

The engine's own protocol log is redacted before it leaves the process, so
a per-attempt TLS reason is not recoverable from captured evidence; the
notification-timeline instrumentation in `tools/run_openvpn_e2e.ps1` now
records the engine's status line per attempt for future runs. All of this
is recorded as NOT VERIFIED rather than smoothed over.

## 4. Windows

| Check | Result |
| --- | --- |
| `tools/fetch_openvpn_bundle.ps1 -Force` then `-VerifyOnly` | **Verified**: both archives match their pinned SHA-256 before extraction, and the six installed files re-hash to the same values |
| Plugin + helper build | Standalone CMake 4.3.1 + MSBuild 19.51 (`-G "Visual Studio 18 2026" -A x64`) → **0 errors, 0 warnings** under `/W4 /WX`; `phantrix_platform_plugin.dll` 171,520 B, `phantrix_ovpn_helper.exe` 90,112 B |
| Helper elevation | `requireAdministrator` manifest present in the built bytes; `CreateProcessW` on it returns `ERROR_ELEVATION_REQUIRED` (740), proving the app itself runs unelevated |
| Helper contract | Purpose-built harness, 37 checks against the **real helper over the real pipe**, including a real `openvpn.exe` launch, token authentication (valid token stays up, wrong token exits 4), deny-list rejection, engine launch, exit classification (`ovpn.config_rejected` for a CA-less profile), stop, clean exit 0 and session-dir removal: **37 ok, 0 fail** |
| Artifact invariants | `tools/check_windows_build.ps1` → **43 ok, 0 fail** (all 21 pre-existing checks unchanged plus 12 new OpenVPN ones) |
| Engine provenance | `dumpbin /dependents openvpn.exe` → import closure is exactly the bundled files plus Windows SDK DLLs |
| `flutter build windows` | **Built** `build/windows/x64/runner/Release/phantrix.exe`, with `phantrix_ovpn_helper.exe`, `openvpn.exe`, `wintun.dll`, `libcrypto-3-x64.dll`, `libssl-3-x64.dll`, `libpkcs11-helper-1.dll`, `vcruntime140.dll` and `phantrix_platform_plugin.dll` all in the bundle |
| Live tunnel | **OBSERVED 2026-10-11** — see the addendum below. The earlier "NOT RUN" line reflected this session being unelevated; a later interactive session approved UAC and connected |

Two races and an import were found by that harness and fixed: a pipe
write-before-connect race (`ConnectNamedPipe` was ignored, so writes to an
unconnected instance are rejected and authentication silently failed), a
blocking-read deadlock (a pending `ReadFile` holds the handle's file lock
and blocks `WriteFile` from another thread, which would have hung
`stopTunnel`), and the missing `libpkcs11-helper-1.dll` import (without it
`openvpn.exe` exits `0xC0000135` with no log — indistinguishable from an
unreachable server).

A `--dev null` probe (no interface, no routes, no admin rights needed)
completed a full TLS handshake with a live VPN Gate relay
(`public-vpn-225`, 219.100.37.219:443/tcp) using the feed's own profile plus
the serializer's two appended lines: `TLS: ... promoted to trusted`,
`PUSH_REPLY,ping 3,ping-restart 10`, cipher AES-128-CBC + SHA1 both
directions, `Initialization Sequence Completed`. Extended to the first 8
feed rows, **all 8 completed** (`probe-public-vpn-*.log` in
`$env:TEMP\vg-verify`, disposable outside the repo). A byte-mirror of the
serializer's exact directive set for the same row (no `cipher` line,
`data-ciphers` + `data-ciphers-fallback`, `pull-filter ignore
"redirect-gateway"`, `redirect-gateway def1`, `block-ipv6`) completed in
**6.1 s** — profile parity between what the app sends and what negotiates
is proven, not assumed. Ranking the feed with the app's own
`ServerSelector` (temporary diagnosis test, removed afterwards) shows the
app's picks are low-ping residential relays on odd high ports, not the
feed's first rows; probing the app's actual top-8 picks from desktop gives
**6/8 completing in 3–6 s** (`vpn591489135` :1783/udp and `vpn449287030`
:995/tcp never answer — dead for every endpoint, with matching TCP timeouts
from the emulator shell for the two TCP cases). The top pick
(`vpn644177666`, 133.32.135.174:6804/udp) was re-probed from desktop
immediately before an emulator run and completed in 3 s. A later ranking
(JP `vpn463711899` 218.221.112.192:1551/tcp, US `vpn208397534`
68.109.69.75:1808/tcp, KR `vpn270108017` 222.117.16.150:995/tcp) completed
**all three from desktop within the same minutes** the emulator attempted
them, and all three are TCP-reachable from the emulator shell — so a
same-window emulator failure against them isolates above the transport
layer.
That isolates the profile shape and cipher negotiation as working; the
remaining Android gap is relay liveness as seen from the emulator and the
(now fixed) timestamp split, not the profile. The probe script initially
reported all 8 as timeouts because the engine keeps running after the
handshake under `resolv-retry infinite` and the jobs were killed while
healthy — the outcome was re-read from the logs' markers, and the false
labels are recorded here rather than silently corrected.

### §4 addendum: the app-driven Windows tunnel was observed (2026-10-11, evening)

After the adapter-registration fix (§5 item 13) and the two fixes below, an
app-driven tunnel was established and verified to forward traffic:

- `20:43:03` — `Initialization Sequence Completed`; adapter `Phantrix` Up at
  `10.211.1.37`, routes `0.0.0.0/1` + `128.0.0.0/1` via `10.211.1.38`;
- `20:43:09` — exit IP moved `203.0.113.5` → `59.130.24.201` (the relay's
  own address), confirmed by a fresh-process `curl` watcher **and** a direct
  read while the adapter was Up;
- held connected 6.5+ minutes with the exit address unchanged.

Full record: `docs/evidence/openvpn/WINDOWS_VERIFICATION_2026-10-11.md` §4;
raw capture: `live-capture-2026-10-11-honest.log`. One observation on one
machine — it supersedes the "NOT RUN" above, it is not a regression suite.

### §4 addendum B: WireGuard availability is a reported capability (2026-10-16)

The Windows backend drives the user's own **WireGuard for Windows**
installation; it is not bundled, and the app had no way to tell whether it was
there. The Dart resolver answered `ProtocolKind.wireGuard => true`
unconditionally, so on a PC without it every WireGuard server was offered,
every attempt reached the engine-launch step, and each one ended in
`backend.not_installed` from a program that does not exist — while the app
told the user to import a WireGuard configuration to do the very thing it
could not do.

What changed:

- `phantrix_windows_plugin.cpp` probes the two documented install locations
  for `wireguard.exe` (the same probe the tunnel path already used) and
  reports `wireGuard` in `capabilities` next to `openVpn`. The `engine`
  string and the `limitations` prose are composed from both answers, so a PC
  without WireGuard is told that rather than handed the static "WireGuard
  needs WireGuard for Windows installed separately".
- `PlatformCapabilities.wireGuard` carries the answer, defaulting to `true`
  when a backend does not report the key — every platform but Windows bundles
  the engine, and their backends predate it.
- The resolver's `_supports` consults it, and `_poolForSelection` drops
  unrunnable servers **before** ranking instead of rejecting the winner after
  it. A WireGuard relay can no longer beat an OpenVPN relay that would have
  connected, and an all-WireGuard list now names the missing engine instead of
  reporting "no server currently passes the health and trust checks".
- An imported configuration (always WireGuard) is checked in
  `connectToConfiguration`, and the Configurations screen states the problem
  and disables Connect rather than offering a button that can only fail.
- `ConnectionController.refreshCapabilities()` re-probes before a connection
  is decided, so installing WireGuard for Windows while the app is open is
  noticed on the next attempt instead of needing a restart — the advice the
  app gives can actually be followed.

Observed on this machine, which has no WireGuard for Windows installed:
`tools/check_windows_build.ps1` → **All checks passed**, including the OpenVPN
bundle checks; the running release build reports on Home

> WireGuard for Windows is not installed on this PC, so WireGuard servers
> cannot be used until it is.

and still offers "Choose a location" with the OpenVPN engine present. The
WireGuard tunnel itself remains unrun here: that needs WireGuard for Windows
installed *and* an administrator token, and §6 is unchanged on that point.

## 5. What the live runs found, and fixed

The first live runs (`tools/run_openvpn_e2e.ps1`, Android emulator, API 34)
exposed two defects that no host-side test could see, because they only
exist when the engine is really running:

1. **A fatal crash on the first engine status event.**
   `java.lang.RuntimeException: Methods marked with @UiThread must be
   executed on the main thread. Current thread: OpenVPNManagementThread`.
   The OpenVPN engine reports through `VpnStatus` on its own management
   thread, and the bridge wrote to the `EventChannel` from there. Every
   Flutter platform-channel write must be marshalled to the main thread.
   Fixed in `EventChannelListener.send`, which now posts through a main
   `Handler` and runs directly when already on the main thread, so every
   caller is safe by construction. The same fix covers the WireGuard
   backend's callbacks, which arrive on another thread as well.
2. **A UI label that overclaimed.** The session stats panel rendered
   "Connected for —" while the tunnel was still being built, because it is
   shown whenever the app is busy. It now reads "Session" until a
   connection is actually verified. (This is also what the live test's
   first `connected` detection matched — a false positive that has been
   turned into an exact-match assertion.)

Two further findings from the earlier runs are recorded rather than fixed
in product code: the WireGuard path reported a spurious `disconnecting`
when the OpenVPN engine stopped (fixed during Phase 2 with a `hasSession`
guard), and the consent flow needed the driver to locate the dialog's OK
button through `uiautomator` rather than guessed coordinates.

One suspected artifact was checked and cleared: stale pooled HTTP
connections reusing a pre-tunnel socket could theoretically explain an
unchanged exit IP, but Dart's `HttpClient` idle timeout (15 s) is far
shorter than any attempt (45 s+), so the verification probe always opens a
fresh socket. Same-IP readings are genuine bypass evidence, not pooling.

3. **The temporary profile was never deleted.** After a run, `run-as`
showed `files/temporary-vpn-profile.vp` (7.8 KB, two private-key markers,
no engine activity for 105+ s) still on disk: every stop removed
`<uuid>.vp` — a file never created — while the real temp file survived.
Root-caused to bytecode with `javap -c` on the pinned AAR:
`saveProfile` branches on `mTemporaryProfile` to the fixed name
`temporary-vpn-profile.vp`, while `removeProfile` unconditionally deletes
uuid + `".vp"`. Fixed in `OpenVpnEngine.removeStoredProfile`, which now
deletes the fixed filename explicitly (coupled to the pinned artifact by a
comment, since it is the engine's private constant), with failures logged.
`VPNList.xml` was verified to hold no key material (0 markers); the
24-byte `profileInstalled` file is binary engine metadata. On-device
confirmation of the fix is pending the next instrumented run, whose driver
carries a filename-only watchdog for exactly this file.

4. **Test-harness friction, fixed in the harness.** The home screen ticks
   every second, so `pumpAndSettle` never returns while it is visible and
   throws after its timeout — one survey run died this way inside a
   navigation helper. The live test now uses bounded pumps everywhere.
   Survey taps are attributed by the card actually on screen rather than
   by the query typed, after one run showed the search filter lagging a
   query behind (a tap meant for one country hit the previous card).

5. **The handshake timestamp never reached the verifier.** A later live run
   reached further — the engine reported its `handshaked` stage — and still
   failed with `leak.unverified`, because the timestamp and the state travel
   as *two* channel events and arrived in the wrong order: the undated
   `handshaked` state first (verification ran against a null timestamp and
   failed), the dated statistics second (too late to matter). The engine had
   actually completed a handshake; the app discarded the evidence. Fixed on
   both sides of the contract: `OpenVpnEngine` now sends the dated
   statistics *before* the undated state (the channel preserves send order,
   so the order is contractual), and the controller never lets an undated
   duplicate clobber a dated handshake it already holds
   (`?? _lastHandshakeAt`, in both the `handshaked` and `established`
   branches). Two unit tests pin the behaviour: dated-then-undated still
   connects, and an undated echo during a reconnect no longer tears down a
   live tunnel. The WireGuard path never had this shape — its statistics
   event carries state and timestamp together — so it is unaffected.


6. **Windows capabilities crashed the parser on first launch.** The Windows backend sends limitations as one prose string while Android sends a map; Dart assumed a map (as Map? on a String throws), so capabilities() failed on every Windows start and the app believed no engine existed on a machine with a verified bundle beside the exe - the exact screen a user reported with a _capabilitiesFrom stack trace. This also explains why no elevation prompt ever appeared on that machine: the refusal happened before the code that asks Windows for UAC consent was reached, so Windows had nothing to prompt about. Fixed in _capabilitiesFrom (accept either shape; a lone note becomes one entry), with a regression test feeding a Windows-shaped report through the real method channel.


7. **Verification raced the routes and refused working tunnels.** The exit-address probe ran the instant the handshake event landed, but the routes that carry traffic through the tunnel are installed just after it: a live run read the pre-tunnel address in that window and reported `leak.unverified` ("public address did not change") against a relay that was actually working - the same relay, attempted again seconds later, verified and carried traffic (the Android gate session). A second live run produced both outcomes for the same relay back to back. On a phone the OS consent dialog is not part of this: Android shows it once per install and remembers the grant, so a silent attempt with a red error is the normal shape of this bug there — the red card, not the missing prompt, was the defect. Fixed in `LeakCheck`: an unchanged or unreachable reading is now re-read up to `LeakCheck.maxReads` times with a pause between reads (a changed address still passes on the first read, without retries); the refusal message states that the address was re-checked over several seconds. Four new tests pin the behaviour: a baseline-matching first read is retried and then verifies, an unreachable first pass is retried and then verifies, the retries are bounded with recorded pauses, and a changed address is accepted immediately.

8. **Windows could not find its own engine — before elevation was ever
   asked for.** The "WireGuard only" notice (item 9) was, on Windows, not
   stale copy but a true reading of a broken probe: `OpenVpnDirectory`
   resolved the engine as `<plugin dir>\openvpn\openvpn.exe`, while the
   Flutter generated-plugin rule installs every bundled library *flat*,
   beside the executable — so `openvpn.exe`, `wintun.dll` and the
   engine's DLLs sat on disk while the probe reported them absent.
   Every consumer failed together: `capabilities()` answered
   `openVpn: false` (the app told users it was WireGuard-only), the
   resolver refused every public relay, `startTunnel` returned
   `backend.not_installed` ("the engine is not bundled in this build"),
   `requestPermission` reported no backend — so no UAC prompt could ever
   appear — and the elevated helper's own gate would have rejected the
   launch too. That is a refusal chain *in front of* procedure B, not
   behind it. The check meant to catch this,
   `tools/check_windows_build.ps1`, only knew the subdirectory layout
   and ran its engine block inside `if (Test-Path ...)`: absent, so the
   block was skipped as "not fetched" and it reported **43/43 passing**
   against a bundle the product could not use. Fixed in
   `OpenVpnDirectory`, which now prefers the subdirectory when it holds
   the engine and falls back to the flat copy beside the plugin — the
   helper and `Engine::Start` resolve through the same function, so one
   fix covers every consumer. The check now recognises both layouts,
   fails when a *fetched* engine never reached the bundle, and runs
   `openvpn.exe --version` against the layout actually present: the
   first time that import-closure check has executed on a real build,
   and it passes (`docs/evidence/openvpn/windows-build-check.txt`).
   The flip is visible in evidence:
   `windows-engine-notice-before.png` (probe said absent, notice shown)
   versus `windows-engine-notice-after.png` (notice gone — by item 9's
   gate its absence *is* the capability reading, and an unknown
   capability would still show it). Still NOT VERIFIED: an app-driven
   Windows tunnel, which needs procedure B.

9. **The "connects through WireGuard only" notice was unconditional.**
   Both the dashboard and the Locations screen showed the notice telling
   users to import a WireGuard file — including on Android, where the
   platform reports an OpenVPN engine and the same build had already
   connected twice through it. The claim is about the build, so it is
   now gated on the capability in both places: `!view.platform.openVpn`
   on Home, and an `openVpnSupported` capability threaded to the
   Locations screen through `DiscoveryGate` (read fresh at every screen
   entry, because destinations are built when selected). Unknown
   capabilities still count as unsupported — the same conservative
   reading the resolver applies — so a build that genuinely cannot run
   OpenVPN is still told so, with the alternative offered. Four tests
   pin both directions: two app-boot tests against a mocked method
   channel (capable build sees no notice, incapable build does) and two
   direct `LocationsScreen` renders with a populated OpenVPN feed.

10. **Automatic selection could bet the whole attempt on one dead
    relay.** The Windows run that failed at 18:40 ("The connection did
    not complete within 45s: the engine never reported a handshake")
    was reproduced *without the app*: the ranking replayed from the
    app's own cached directory (fetchedAt 17:40Z, the real
    `ServerSelector`) put `vpn703894277` at rank #0, and the bundled
    engine running that relay's own profile sat in silence for 45s —
    UDP to `130.62.15.40:40792`, no peer, no TLS. Ranks #1 and #2
    never even completed a TCP connect. Raw TCP controls
    (`219.100.37.207:443` and `1.1.1.1:443` both fine, and
    `public-vpn-253` completing a full handshake minutes later on the
    same machine and network) rule out the connectivity: those
    relays were unreachable from this network at that moment. The
    ranking reads the provider's ping/uptime columns, which are
    measured from somewhere else, so a dead relay outranks a live
    busy one — the load term even penalises the relay that has
    users, i.e. the one that is demonstrably up. Worse, `retry()`
    replayed the *same* dead relay, because a handshake timeout is
    "replayable": Try Again looped the black hole. Fixed where the
    promise is made — an automatic connect (`recommended` or
    `fastest`) now *walks* the ranking, up to 6 servers at 20s each,
    stopping at the first verified handshake. Only silence walks: a
    diagnosed failure (rejected configuration, refused consent,
    failed exit-address check) stops the walk and keeps its message,
    because it describes the attempt, not just that server. When the
    walk runs out, the failure says exactly that
    (`tunnel.no_relay_reached`, "Tried N servers…"), and a retry
    re-runs selection instead of repeating the last silent server. A
    named server — explicit, favourite, or recent — is never walked,
    because substituting it silently is the lie the selection rules
    forbid. Four tests pin all of it. Known cost on Windows: the
    elevated helper is one-shot per attempt, so each walk step
    re-prompts UAC — honest but clicky; the follow-up is a
    single-elevation helper that walks endpoints itself.

11. **A fatal engine exit could report the sentence that names nothing.**
    The user's own run this evening hit `ovpn.engine_exited` with the
    reason `2026-10-10 19:35:29 Exiting due to fatal error`. OpenVPN
    appends that exact sentence — `msg(M_INFO, "Exiting due to fatal
    error")` in `src/openvpn/error.c` — after *every* fatal error,
    immediately after the line that names the cause. The engine's error
    capture kept the *last* matching line, which is the terminator, so
    the reason shown to the user was the same blank sentence no matter
    what killed the engine. Fixed in `OnOutputLine`: the generic
    terminator never overwrites an already-captured cause line,
    `Assertion failed …` lines (another fatal that carries no `ERROR:`
    prefix) are captured too, and the survivor then goes through the
    existing exit classifier — a TUN-driver failure, for instance, now
    reports as `ovpn.driver_failed` with its own sentence instead of
    `ovpn.engine_exited` plus the terminator. The elevated helper
    rebuilds with this fix; today's two user errors, the live silent
    session, and the stderr-vs-`--log` probes are recorded in
    `docs/evidence/openvpn/windows-user-errors-2026-10-10.txt`.

12. **The Windows WireGuard branch never asked the engine anything.**
    On Windows the WireGuard path installed the tunnel service,
    published `established`, and stopped there: the helper's
    `handshaked`/traffic events were wired only to the OpenVPN path, so
    on a WireGuard connection Dart's 45-second gate always elapsed even
    when the tunnel was up, and the user was told "the engine never
    reported a handshake" about a tunnel that had one. Fixed with a
    handshake monitor that polls the official `wg.exe` beside
    `wireguard.exe` — `wg show <interface> dump`, the documented
    machine-readable form, trying both the bare tunnel name and
    `WireGuardTunnel$Phantrix` — once a second and posts the peer's
    handshake time and byte counters to the platform thread. Only a
    nonzero handshake is ever reported and a failed query stays silence;
    no protocol or crypto is reimplemented, the monitor reads the same
    fields the WireGuard UI reads, and the capture is bounded both in
    bytes and in time. The client is located by the same fixed-path rule
    as `wireguard.exe`, never from `PATH`. Built and checked statically;
    a live Windows handshake still needs procedure B (one interactive
    UAC click) to confirm end to end.

13. **The Windows engine could not see the Wintun adapter the helper created.**
     This is why every Windows connection failed, on every PC, and it is a
     shared software defect rather than a relay or machine problem.
     Reproduced directly with the app's own serialized profile and the
     helper's exact argument vector: the engine negotiates TLS in full —
     `VERIFY OK: depth=0, CN=opengw.net`, `TLSv1.3
     TLS_AES_256_GCM_SHA384`, `Peer Connection Initiated`,
     `PUSH_REQUEST`/`PUSH_REPLY` — and then dies at `open_tun` with
     `There are no TAP-Windows, Wintun or ovpn-dco adapters on this
     system.` The relay, the profile, the DLLs and the argument vector
     are all correct; the adapter is not.
     The cause is in `src/openvpn/tun.c`'s `get_tap_reg()`: it enumerates
     `HKLM\SYSTEM\CurrentControlSet\Control\Class\{4D36E972-…}` and keeps a
     subkey only when its `ComponentId` equals `wintun` (or `tap0901`,
     `root\tap0901`, `ovpn-dco`). `tun_open_device()` then calls
     `at_least_one_tap_win()`, which raises that exact `M_FATAL`
     **before** the `--dev-node` lookup — so a correctly named adapter is
     still unfindable. Wintun's own INF, verified on a real PC at
     `C:\Windows\INF\oem81.inf`, declares `Class = Net` but writes **no
     `ComponentId`**: its only `AddReg` target is `[Wintun.Ndi]`, and
     `HKR` in a `DDInstall` section is the device's *hardware* key, not
     the Net-class key the engine reads. TAP-Windows escapes this because
     its INF writes `HKR,,ComponentId,0x00010000,"tap0901"` explicitly;
     Wintun has no equivalent line, so an adapter created through the
     Wintun API is invisible to OpenVPN. Android is unaffected —
     ics-openvpn builds its `tun` through `VpnService`, which needs no
     registry adapter and no `--dev-node` at all.
     Fixed in `phantrix_ovpn_helper.cpp`: after creating the adapter, the
     helper now finds the adapter's own `NetCfgInstanceId`, writes
     `ComponentId = wintun` into the one class subkey that belongs to it,
     reads the value back to confirm it held, and restores the subkey
     exactly as it found it when the session ends. A registration that
     cannot be completed or confirmed stops the attempt with
     `ovpn.driver_not_registered` rather than launching an engine that
     would die at `open_tun`. No other adapter is touched, no hash check
     or signature verification is bypassed, and UAC is not weakened.
     Verified by unit test (18 tests, each checked against deliberate
     sabotage of the source) and by a real-pipe harness against the real
     helper; the one thing still unobserved is the adapter becoming
     discoverable, which needs an administrator token.
     Evidence: `docs/evidence/openvpn/WINDOWS_ROOT_CAUSE.md` and
     `docs/evidence/openvpn/WINDOWS_VERIFICATION_2026-10-11.md`.

## 6. NOT VERIFIED / NOT RUN (honest list)

| Item | Why | Where it is tracked |
| --- | --- | --- |
| Live tunnel on the physical device | **Now run and verified** (§3): connected=true, exit IP moved to 60.119.0.51, 104.7 KB / 105.0 KB through the tunnel, clean disconnect. MIUI install no longer refused | **[historical]** — the Android engine behind this result was removed 2026-10-13 |
| Live tunnel on Windows | **OBSERVED** (§4 addendum): `Initialization Sequence Completed`, exit IP `203.0.113.5` → `59.130.24.201`, held 6.5 minutes | Closed as of 2026-10-11; `docs/evidence/openvpn/WINDOWS_VERIFICATION_2026-10-11.md` §4 |
| Live tunnel on the **release** APK (Android) | **[historical]** Never ran; the release-mode end-to-end was launched but the phone dropped off USB before `adb wait-for-device` returned | Moot — Android has no OpenVPN engine |
| Engine teardown path (`stopVPN` → profile removal) | Inspected in AAR bytecode, never executed | **[historical]** — AAR and bridge removed |
| Per-app / LAN policy (`allowedApps`, `disallowedApps`, `allowLan`) | No settings exist to set them; the Dart controller correctly omits them and the native parsers accept null | Documented in the controller's call site |
| `customDns` reaching the engine end-to-end | Parser fix verified by a JVM unit test; the on-device path remains to be exercised | **[historical]** — the Android engine was removed |
| R8 consumer rules for the engine (`consumer-rules.pro`) | The release build through the Flutter tool succeeds; the raw-Gradle path the agent used cannot see the release registrant | **[historical]** — the engine keep-rules were removed with it |
| CI format gate | Already red at baseline for ~90 files before this work | §2 note |

## 7. Known gaps carried forward (not fixed here, deliberately)

| Gap | Why it is open | What would close it |
| --- | --- | --- |
| **OpenVPN credentials.** `TunnelRequest` carries no username/password, so a profile whose `auth-user-pass` is not satisfied by inline files is refused with `ovpn.credentials_missing`. Every credential-based OpenVPN server is unusable today | Adding a secret field to the frozen channel contract means specifying how the secret is stored (OS keystore), redacted and transmitted — a design decision, not a bug | A `credentialsRef` field plus keychain storage on both platforms, then the same live-tunnel test against a credential server |
| `reportVerification` is a no-op on both platforms | The method exists in the contract but nothing consumes its result natively | Decide what native effect it should have (e.g. the engine's own verification record) and implement it |
| Repeated `handshaked`-with-counters as the traffic convention (Windows) | Both Windows paths now emit it — the OpenVPN helper's status poll and the new WireGuard `wg.exe` monitor — and the Dart sink has always accepted it, but the convention is not written into the frozen contract | Agree the convention in the frozen contract (or specify another) before a platform other than Windows depends on it |
| Nothing reads `capabilities.engine` | The Windows plugin reports `"openvpn-community + wireguard-for-windows"`, or one of them, or `"none"`; the Dart side never distinguishes engines | Surface it in Diagnostics, or drop the field |
| Windows `capabilities.supportsIpv6Blocking` is `false` | IPv6 blocking on Windows comes from the profile's `block-ipv6`, not the backend | Report it as supported once that behaviour is asserted on a live tunnel |
| Per-app / LAN policy (`allowedApps`, `disallowedApps`, `allowLan`) | No settings exist to set them; the controller correctly omits them and the native parsers accept null | A split-tunnel screen that writes them, then the same live test |
| **Same-user pipe piggyback (Windows).** The session token is 128-bit
  CSPRNG but travels on the helper's command line (readable by any
  same-user process); the pipe's DACL admits the same user; the session
  directory is user-writable. A same-user process active during a tunnel
  could read the token, authenticate to the pipe, plant its own profile,
  and have the elevated helper run `openvpn.exe` with attacker routes/DNS
  — a UAC-bypass gadget, since the profile still passes the deny-list but
  needs no prompt. Nothing about this was observed exploited; it is a
  design-level finding from review | Verify the pipe peer with
  `GetNamedPipeClientProcessId` against the known `--parent` pid at hello
  (fail closed when they differ); verify with the elevated harness before
  shipping Windows OpenVPN |
| `flutter analyze --fatal-infos --fatal-warnings` on the generated notices file now depends on generator output | The generator must stay analyzer-clean for the checked-in file to be | Kept in one list: `dart run tools/generate_third_party_notices.dart && flutter analyze` |
| CI format gate (`dart format`) | Already failing at baseline for ~90 files before this work; reformatting would rewrite nearly every file | A dedicated formatting commit, reviewed on its own |

## 8. Phase 5 follow-ups

Items whose subject was removed with the Android OpenVPN engine are marked
**[moot]**; the driver `tools/run_openvpn_e2e.ps1` and the test
`integration_test/openvpn_live_tunnel_test.dart` no longer exist.

1. **[moot]** Android live run (see the note above — the tooling is deleted).
2. Revocation test: withdraw VPN permission while connected and confirm the
   app reports `revoked`.
3. Protocol-swap test: WireGuard then OpenVPN without stopping, and confirm
   exactly one tunnel survives — Windows only now, since Android has one
   engine.
4. Windows: build the plugin and helper with cmake/VS 2026, run
   `tools/check_windows_build.ps1`, and record which checks pass.
5. Windows live tunnel: **done once** (§4 addendum). Re-run it on the machine
   and build you intend to ship; a single observation is not a regression test.
6. **[moot]** Revocation and protocol-swap tests on the removed Android
   OpenVPN engine.
7. Live-observed DNS behaviour on Windows, and a live reconnect/revocation
   cycle — still open. The Windows handshake, traffic and disconnect are
   verified (§4 addendum); DNS and reconnect are not, in any environment
   available here.

### Manual procedure A: Xiaomi/MIUI physical device

**[historical]** The tool this procedure drives (`tools/run_openvpn_e2e.ps1`)
was deleted with the Android OpenVPN engine on 2026-10-13. Kept as reference
only.

*(Resolved while it existed: the device `794fedaa` installed and ran
a full verified tunnel — §3. This procedure is kept as reference for any
other MIUI phone where the gate is still enforced.)*

On a MIUI phone where `adb -s <serial> install` fails with
`INSTALL_FAILED_USER_RESTRICTED: Install canceled by user`, this is the
"Install via USB" gate, and every step needs hands on the phone:

1. Settings → About phone → tap **MIUI version** 7 times until Developer
   options unlock.
2. Settings → Additional settings → Developer options → enable **USB
   debugging**.
3. On the same screen enable **Install via USB**. MIUI requires a Xiaomi
   account signed in on the device for this toggle (some versions also need
   a SIM inserted); if the toggle flips back off, sign in first and retry.
4. On the same screen enable **USB debugging (Security settings)** — the
   E2E driver approves the VpnService consent dialog with `adb shell input`,
   which this toggle permits.
5. Reconnect USB, accept the "Allow USB debugging?" RSA fingerprint prompt
   on the phone, then from the host run
   `powershell -File tools/run_openvpn_e2e.ps1 -Serial 794fedaa`.
6. Expected evidence on success: `LIVE TUNNEL OUTCOME: connected=true` in
   `docs/evidence/openvpn/e2e-test-output.txt`, a changed public IP in the
   verification message, and a clean disconnect. Anything less stays NOT
   RUN — a timeout is a timeout, not a connection.

Menu names vary by MIUI version; the procedure above matches MIUI 13/14
(the device runs Android 13). It could not be executed here: the phone is
not attached to this host.

### Manual procedure B: Windows elevated live tunnel

**Run the native check first — it answers the question in about a minute and
needs no app.** From an **Administrator** PowerShell prompt:

```powershell
.\phantrix_adapter_probe.exe `
  "$repo\build\windows\x64\runner\Release\wintun.dll" `
  "$repo\build\windows\x64\runner\Release" `
  "$env:TEMP\vg-profile.ovpn" `
  --run
```

It creates a real Wintun adapter, applies the registration the helper now
performs, launches the bundled `openvpn.exe` against the live relay, and then
restores the class key. The output to look for is
`Initialization Sequence Completed` in the engine log — that is the adapter
being seen by the engine, which is what item 13 was about. The full procedure,
both variants, and what each result means for a second PC:
`docs/evidence/openvpn/WINDOWS_LIVE_VERIFICATION.md`.

Then, for the app-driven run, the helper cannot be launched without approving
UAC, which needs an interactive administrator session:

1. From an unelevated shell, confirm the bundle first:
   `powershell -NoProfile -ExecutionPolicy Bypass -File tools\fetch_openvpn_bundle.ps1 -VerifyOnly`
   (must report every file matching its pinned hash).
2. Build: `flutter build windows` (must complete; the bundle lands beside
   `phantrix.exe` with `phantrix_ovpn_helper.exe`, `openvpn.exe`,
   `wintun.dll` and the runtime DLLs).
3. Launch the built `phantrix.exe`, pick a VPN Gate server, and press
   Connect. Approve the UAC prompt for `phantrix_ovpn_helper.exe`.
   Declining must surface a failure, never a silent return.
4. Expected evidence on success: the helper's log shows `Initialization
   Sequence Completed`; the app reports connected only after its own
   handshake-plus-address verification; `ipconfig` shows the wintun
   adapter with the pushed address; an external IP check differs from the
   pre-connection address; Disconnect removes the adapter and deletes the
   session directory (`%LOCALAPPDATA%\Phantrix\…\session-*`).
5. Record the outcome — including a failure — in §4 with the exact server,
   the helper log lines (redacted), and the exit classification.

## 9. Release blockers

Ordered by what stands between this tree and a release someone may trust.
Blockers that the Android engine removal (2026-10-13) or the Windows live run
(2026-10-11) closed are listed as closed, not silently deleted:

1. **[closed 2026-10-11] No handshake had completed *through the app* on
   Windows.** An app-driven tunnel was then observed: exit IP
   `203.0.113.5` → `59.130.24.201`, held 6.5 minutes (§4 addendum,
   `docs/evidence/openvpn/WINDOWS_VERIFICATION_2026-10-11.md` §4). One
   observation on one machine is evidence the path works, not a guarantee;
   repeat it on the machine you ship for.
2. **[closed by removal] The bundled OpenVPN 3 core's exact source and licence
   application.** `libovpn3.so` shipped inside the AAR and is gone with it.
3. **[closed by removal] Corresponding Source was not offered for the vendored
   AAR.** No AAR ships, so no source is owed for it.
4. **[closed by removal] The licence grant for the exact Android AAR was
   unresolved.** The engine was removed rather than relicensed around.
5. **wintun redistribution reading is open** (§1b Q3).
6. **Same-user pipe piggyback on Windows** (§7): token-on-cmdline plus
   same-user pipe access admits a UAC-bypass gadget during an active
   tunnel. Needs the client-PID check plus elevated-harness verification
   before the Windows backend ships.
7. **DNS behaviour on Windows is engine-default, not enforced**: no
   `--block-outside-dns`, no explicit resolver handling in the helper
   (the Android engine used to override resolvers per policy; it no longer
   exists, and Windows never did). Unmeasured — the verifier explicitly does
   not cover DNS (see `leak_check.dart`: "DNS is not leaking" is listed under
   what the check does *not* prove).
8. **No kill switch exists on any platform.** Android reports the OS's own
   Always-on/blocking state live and says plainly the app cannot block
   traffic itself; Windows offers nothing equivalent. The settings copy
   states this, but it remains the largest protection gap in the product.
9. **Android has no OpenVPN backend at all.** VPN Gate relays and imported
   `.ovpn` files are refused on Android by design (`docs/LICENSING_AUDIT.md`).
   That is a product limitation, not a licence blocker.

## 10. DNS, IPv6 and traffic-blocking posture (implemented / tested / not)

| Protection | Android | Windows | Status |
| --- | --- | --- | --- |
| Full-tunnel routing | `redirect-gateway def1 bypass-dhcp` in every serialized profile + `mUseDefaultRoute=true` | Same profile text; engine applies pushed + local routes | Implemented both; **live-unverified** |
| IPv6 blocking (default) | `block-ipv6` in profile + `mBlockUnusedAddressFamilies=true` + `mUseDefaultRoutev6=false` unless explicitly allowed | `block-ipv6` in profile only; capability honestly reports `false` | Implemented both; **live-unverified** |
| DNS enforcement | Server resolvers by default; TRUSTED appends user resolvers; CUSTOM replaces (empty list refused); invalid entries refused | None: engine default + server push; no `--block-outside-dns` | Android enforced iff TRUSTED/CUSTOM selected (**untested live**); default VPN mode and Windows rely on pushed resolvers — and the sampled relays push **none** (`PUSH_REPLY,ping 3,ping-restart 10` only), so resolution falls back to the device's pre-existing resolvers through unknown paths. **Unmeasured everywhere; likely leaking by default.** |
| Kill switch / traffic blocking | None in-app; OS Always-on + "block without VPN" reported live | None at all | **Unimplemented** by design decision; UI states this |
| Per-app routing / LAN bypass | Implemented natively (`mAllowedAppsVpn`, `mAllowLocalLAN`) but **never sent** — no settings exist, controller omits the fields | Reported `false`; nothing implemented | Unwired/unimplemented |
| Post-handshake verification | Handshake observed + fresh (≤3 min) + public IP changed; DNS explicitly out of scope | Same | Implemented + unit-tested; **live-unverified** |

---

# Appendix: changed files

Commits `ffc58c5`, `2c9b61a`, `9103fed`, `ddc0e0a`, `b542595` and
`a1a6876` carry the work so far (plus the owner's `ed2f834`, the
exit-address race fix); the latest round — engine-layout resolution, the
notice gating and their tests — is in the commit carrying this update.
Everything below is the complete change set for this work, by area.

## Flutter / Dart (app)

| File | What |
| --- | --- |
| `lib/vpn/connection_controller.dart` | Consent-first connect, 45s connect deadline, replay-vs-re-select retry, `ovpnConfig` serialisation, disconnect completion; this round: unexpected engine death mid-attempt becomes `tunnel.died` instead of silence, undated handshake duplicates never clobber dated ones, a new attempt retires the previous error; and now: per-attempt deadline budgets, `connectAndAwait` reporting a terminal outcome to a caller that may try several servers, and a new attempt waiting for the previous failure's teardown before it starts |
| `lib/vpn/connection_resolver.dart` | Capability-aware protocol rejection with actionable errors; this round: automatic connects walk the ranking (6 servers × 20s, silence-only, honest exhaustion summary, retry reselects) |
| `lib/vpn/leak_check.dart` | Protocol-aware leak messages; correct article in the no-handshake message; this round: unchanged or unreachable exit readings are re-read up to `maxReads` times with a pause before judging (the probe raced route installation and refused working tunnels) |
| `lib/phantrix_app.dart` | `licenses` destination, `onOpenLicenses`, **MaterialLocalizations fix** (Arabic previously crashed every Material widget); `openVpnSupported` capability passed to the Locations destination |
| `lib/l10n/strings.dart` | EN + AR for the licences page and every `licensesNote_*` |
| `lib/ui/screens/licenses_screen.dart` | New: the in-app Licenses & credits page |
| `lib/ui/screens/settings_screen.dart` | New ? entry in About |
| `lib/ui/screens/home_screen.dart` | Session stat no longer says "Connected for" before a session exists; the WireGuard-only notice is gated on the `openVpn` capability |
| `lib/ui/screens/locations_screen.dart` | Same notice gated on a threaded `openVpnSupported` capability (it showed whenever the feed was OpenVPN-only — exactly when the claim is wrong) |
| `lib/discovery/discovery_gate.dart` | Passes `openVpnSupported` through to the Locations screen |
| `lib/notices/third_party_notices.dart` | The notice inventory contract |
| `lib/notices/generated_third_party_notices.dart` | Generated inventory (94 entries, 84 licence texts after the engine removal) |
| `pubspec.yaml`, `pubspec.lock` | `flutter_localizations` for the delegate fix |
| `packages/phantrix_core/lib/src/vpn/vpn_state_machine.dart` | `permissionRequired` / `disconnecting`, consent-first transitions |
| `packages/phantrix_core/lib/src/protocol/openvpn/ovpn_serializer.dart` | `block-ipv6` option |
| `packages/phantrix_platform/lib/phantrix_platform.dart` | `TunnelRequest.ovpnConfig`, `PlatformCapabilities.openVpn`; this round: `limitations` accepts a Map or a prose String (Windows sent a String and crashed parsing) |
| `packages/phantrix_core/lib/src/geo/geo_database.dart` | One pre-existing analyzer info fixed |

## Android (native)

**All of the OpenVPN rows below were deleted from the tree on 2026-10-13** when
the engine was removed for licence incompatibility (§1). They are listed so a
reader of the historical evidence can see what the evidence was produced
against. What remains in `packages/phantrix_platform/android/` is the WireGuard
path: `PhantrixTunnelService.kt`, `WgConfigMapper.kt`, `VpnPermissions.kt`,
`RoutingPolicy.kt`, `TunnelRequestParser.kt`, `PhantrixPlugin.kt`,
`AndroidCapabilities.kt` (whose `openVpn` field now reports `false`),
`EventChannelListener.kt` and `AndroidManifest.xml`.

| File (now deleted) | What it was |
| --- | --- |
| `packages/phantrix_platform/android/localmaven/**` | Vendored `icsopenvpn` AAR + POM + upstream `LICENSE.txt` + `NOTICE` + `PROVENANCE.md` |
| `.../OpenVpnEngine.kt`, `OpenVpnProfileFactory.kt`, `OpenVpnDirectivePolicy.kt`, `OpenVpnStatusMapper.kt`, `OpenVpnTextRedactor.kt` | The OpenVPN bridge: parse to profile, deny-list re-check, status mapping, redaction |
| `.../src/test/kotlin/.../OpenVpn*Test.kt` | 51 JVM tests (the request-parser tests that remain are WireGuard-side) |
| `android/**` gradle + `verification-metadata.xml` | localmaven repo (root-anchored), `useLegacyPackaging`, icsopenvpn pins — all reverted; `verification-metadata.xml` keeps the rest of its 1165 pins |

## Windows (native)

| File | What |
| --- | --- |
| `packages/phantrix_platform/windows/phantrix_ovpn_helper.cpp` + `.exe.manifest` | The elevated helper: pipe server, overlapped I/O, engine supervision, graceful stop |
| `.../phantrix_ovpn_engine.cpp/.h`, `phantrix_ovpn_support.cpp/.h` | Engine config/state/USER-pass/log parsing and redaction; `OpenVpnDirectory` resolves both engine layouts (subdirectory, or the flat copy `flutter build windows` installs); fatal exits keep the cause line, never the generic "Exiting due to fatal error" terminator (§5 item 11) |
| `.../phantrix_windows_plugin.cpp`, `CMakeLists.txt` | Plugin side: `runas` launch, pipe client, state mapping |
| `tools/fetch_openvpn_bundle.ps1` | Hash-pinned download of OpenVPN 2.6.17 + wintun |
| `tools/check_windows_build.ps1` | 43 invariant checks (21 pre-existing + 12 new); the engine block now detects both layouts, fails a fetched engine that never reached the bundle, and runs `--version` against the layout present |
| `packages/phantrix_platform/windows/bundle/.gitignore` | The fetched bundle is not committed |

## Tests, tools and docs

| File | What |
| --- | --- |
| `test/licenses_test.dart` | 12 tests for the page and the generated inventory |
| `test/app_smoke_test.dart`, `test/connection_state_test.dart`, `test/connection_resolver_test.dart` | New / extended expectations, including 9 failure-behaviour tests and 2 handshake-timestamp-ordering tests added during live verification, plus 2 dashboard notice-gating tests against a mocked capabilities channel |
| `test/locations_notice_test.dart` | New: both directions of the Locations notice condition against a populated OpenVPN feed |
| `test/connection_walk_test.dart` | New: the automatic-walk contract — silent first server is left for the next ranked one and it connects; a fully silent walk reports `tunnel.no_relay_reached` and retry reselects; a diagnosed failure ends the walk with its message intact; a chosen server is never silently substituted |
| `packages/phantrix_core/test/protocol/ovpn_test.dart` | Live-feed row serialization round-trip regression test |
| `integration_test/openvpn_live_tunnel_test.dart` | **[deleted 2026-10-13]** The Android live tunnel test plus the per-country relay survey |
| `tools/run_openvpn_e2e.ps1` | **[deleted 2026-10-13]** The Android E2E driver |
| `tools/generate_third_party_notices.dart` | The notices generator |
| `tools/attribution/*` | Third-party licence texts (the six AAR-subcomponent texts went with the engine) |
| `docs/LICENSING_AUDIT.md` | Consolidated licensing conclusions and release gates |
| `README.md`, `THIRD_PARTY_LICENSES.md` | Licences page section, engine sections, why the GPL-2.0-only engine was removed |
| `docs/OPENVPN_BACKEND_VERIFICATION.md` | This report |
| `docs/evidence/openvpn/**` | Live-run evidence: logcat, routes, netstats, notifications, test output; plus the Windows engine-notice before/after captures and the 43-check output including the engine `--version` run; plus the §5 item 10 reachability controls: rank #0/#1/#2 silence logs, the live `public-vpn-253` handshake control, and `windows-walk-reachability-controls.txt`; plus `windows-user-errors-2026-10-10.txt` (OCR of the two user-reported error screens, the live silent-session log, and the fatal-terminator probes behind item 11) |

## Appendix addendum (2026-10-16): the WireGuard capability

The rows above are the OpenVPN work and are left as written. This is the
separate change that made WireGuard availability a reported fact — §4 addendum
B has the reasoning.

| File | What |
| --- | --- |
| `packages/phantrix_platform/windows/phantrix_windows_plugin.cpp` | `capabilities` reports `wireGuard`, probed from the two documented `wireguard.exe` locations, and composes `engine` (`openvpn-community`, `wireguard-for-windows`, `none`) and the `limitations` prose from both answers instead of one static string |
| `packages/phantrix_platform/lib/phantrix_platform.dart` | `PlatformCapabilities.wireGuard`, defaulting to `true` when a backend does not report the key |
| `lib/vpn/connection_resolver.dart` | `_supports` consults `wireGuard`; `_poolForSelection` takes the capabilities and drops unrunnable servers before ranking; `_noRunnableServer` + `_remedyFor` replace "no server currently passes the health and trust checks" when the pool is empty for a protocol reason; `resolveAndConnect` re-probes before deciding |
| `lib/vpn/connection_controller.dart` | `refreshCapabilities()`, which re-reads the platform's answer and emits only when a protocol flag actually changed |
| `lib/phantrix_app.dart` | `connectToConfiguration` refuses an imported (always WireGuard) configuration when there is no engine, before anything is dialled; the Configurations destination threads `wireGuardSupported` |
| `lib/ui/screens/configurations_screen.dart` | `wireGuardSupported` prop: a list-level note, a per-card note, and a disabled Connect button when the engine is absent. The configuration is kept and its verdict is unchanged — a missing engine is not a broken file |
| `packages/phantrix_platform/test/platform_bridge_test.dart` | 2 new tests: `wireGuard: false` parses as unable; a backend that omits the key keeps it available |
| `test/connection_resolver_test.dart` | 2 new tests: a WireGuard relay loses to a slower connectable OpenVPN one; an all-WireGuard list names the missing engine rather than the health checks |
| `test/configurations_screen_test.dart` | 2 new tests: no engine disables Connect and says so; the same configuration connects once an engine exists |
| `README.md`, `BUILDING.md`, `ARCHITECTURE.md`, this file | The capability, and the honest note that the WireGuard tunnel itself is still unrun here |
## Addendum 2026-10-17: the data-path arguments

Engine::Start (helper-side phantrix_ovpn_engine.cpp) now appends two data-path
flags after the path arguments:

* --sndbuf 524288 --rcvbuf 524288 � the engine's own defaults are 64KB, which
  every session log confirms (Socket Buffers: R=[65536->65536]
  S=[65536->65536]). A cross-continent volunteer relay with even mild packet
  loss stalls on that send window long before the path is filled; half a
  megabyte each way is the conventional remedy.
* --socket-flags TCP_NODELAY � only for profiles whose proto line starts
  with 	cp. Nagle batching delays exactly the traffic a tunnel carries
  (keystrokes, DNS, voice). ProfileIsTcp reads the profile with the same
  capped budget and comment rules as ProfileHasAuthUserPass, because the flag
  is invalid on a TCP-less link and OpenVPN fails to start when it conflicts.

Verified against a live relay the same way the handshake was verified above:
the flags parse, the socket log shows Socket Buffers: R=[65536->524288]
S=[65536->524288], and the TLS negotiation proceeds unchanged. The flag being
conditional is load-bearing, not cosmetic � see lagtest3.log for the
udp-link shape the guard avoids.
