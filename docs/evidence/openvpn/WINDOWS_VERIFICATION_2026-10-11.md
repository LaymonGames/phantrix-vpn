# Windows OpenVPN verification — 2026-10-11

Everything below was executed. Where something could not be run, it says so,
with the reason.

Environment: Windows 11 24H2 (26300), Flutter 3.47.0 / Dart 3.13.0, MSVC
14.51 (VS 18 Community), session **not elevated**.

## 1. Root cause

`openvpn.exe` cannot see a Wintun adapter created through the Wintun API, so
the engine dies at `open_tun` with `There are no TAP-Windows, Wintun or
ovpn-dco adapters on this system.` after a **completed** TLS handshake. Full
analysis, with the source references and registry evidence:
[WINDOWS_ROOT_CAUSE.md](WINDOWS_ROOT_CAUSE.md).

The single sentence: OpenVPN's `get_tap_reg()` keeps a Net-class registry key
only when its `ComponentId` is `wintun`, and **Wintun's INF never writes
`ComponentId`**, so the adapter exists and is invisible.

## 2. The fix

`packages/phantrix_platform/windows/phantrix_ovpn_helper.cpp` now, after
creating the adapter, looks up that adapter's `NetCfgInstanceId` and writes
`ComponentId = wintun` into the one class subkey that belongs to it, reading the
value back to confirm it held, and puts the key back exactly as it found it
when the session ends. A registration that cannot be completed or confirmed
stops the attempt with `ovpn.driver_not_registered` instead of launching an
engine that would die at `open_tun`.

That is 1 value, in 1 subkey, for the adapter this session created — no other
adapter is touched and no machine-wide state is changed. Nothing about hash
checking, signature verification or UAC was weakened.

## 3. What was verified

| Check | Result |
| --- | --- |
| Root cause reproduced with the app's own profile and the engine's exact argv | `open_tun` → `There are no TAP-Windows, Wintun or ovpn-dco adapters on this system` → exit 1 |
| Profile is valid end to end | Full TLS to a live relay: `VERIFY OK: depth=0, CN=opengw.net`, `TLSv1.3 TLS_AES_256_GCM_SHA384`, `Peer Connection Initiated`, `PUSH_REQUEST` → `PUSH_REPLY` |
| Real helper over the real named pipe | Launch, connect, token auth, start, deny-list (12 cases), exit classification, teardown, session-dir removal: **all correct** |
| Bundle contents | `openvpn.exe` 2.6.17 + `wintun.dll` 0.14.1 + `libcrypto-3-x64.dll`, `libssl-3-x64.dll`, `libpkcs11-helper-1.dll`, `vcruntime140.dll`, `phantrix_ovpn_helper.exe`, `phantrix_platform_plugin.dll`, `flutter_windows.dll`, `data/` |
| Built engine runs | `--version` → `OpenVPN 2.6.17`, exit 0; unknown option rejected with a diagnostic |
| `tools/check_windows_build.ps1` | **All checks passed** (all prior OpenVPN and helper blocks) |
| `flutter analyze` | 1 issue — pre-existing `unnecessary_cast` in `test/app_http_fetcher_test.dart`, untouched by this work |
| `flutter test` (app) | **229 passed**, 2 failed — both pre-existing, both unrelated (see §5) |
| `flutter test` (`phantrix_core`) | **184 passed** |
| `flutter test` (`phantrix_platform`) | **21 passed** |
| `flutter build windows` | Built; the shipped `phantrix_ovpn_helper.exe` contains the new strings `ovpn.driver_not_registered`, `The Wintun adapter's driver entry did not hold…` |

### New tests

`test/windows_openvpn_adapter_test.dart`, 18 tests. They verify the fix is
*wired*, not merely present: the registration is called on the success path,
its result is tested, the subkey is found through the adapter's own instance
id, the value is read back, and the class key is restored on teardown. Each was
checked against deliberate sabotage of the source — removing the call,
inverting the `!`, looking up a wrong instance id, dropping the read-back,
dropping the restore, and switching the write to a hardware key — and each
sabotage is caught.

## 4. A completed, verified tunnel on Windows — OBSERVED 2026-10-11 (evening)

The earlier caveat in this section ("no claim is made that a Windows tunnel was
established") is superseded. After the two fixes below, a tunnel was
established **and independently verified to forward traffic**:

- `20:43:03` — `Initialization Sequence Completed`; adapter 44 `Phantrix` Up;
  `10.211.1.37`; `0.0.0.0/1` + `128.0.0.0/1` → `10.211.1.38`
- `20:43:09` — exit IP `203.0.113.5` → **`59.130.24.201`** (the relay's own
  address; a changed exit address, which is the verification criterion)
- Held connected 6.5+ minutes (through `20:49:35`) with the exit IP still
  `59.130.24.201`, confirmed by two independent means: an honest fresh-process
  `curl.exe` watcher, and a direct `curl` read while the adapter was Up.

Capture: [live-capture-2026-10-11-honest.log](live-capture-2026-10-11-honest.log).

Two additional fixes were required beyond the adapter registration, both
committed in `3c69ac9 "FINALLY VPN WORKS ON WIDNOWS"`:

1. **Verifier connection-pooling bug** (`lib/vpn/leak_check.dart`): the
   exit-address check reused a pooled keep-alive socket opened *before* the
   tunnel, so it always read the pre-tunnel address and always reported
   `leak.unverified` even on working relays. Each read now builds a fresh
   `http.Client`. Full write-up in
   [WINDOWS_ROOT_CAUSE.md](WINDOWS_ROOT_CAUSE.md).
2. **Walk-past-non-forwarding-relay** (`lib/vpn/connection_controller.dart`):
   `ConnectAttemptOutcome.walkable` now treats `leak.*` as walkable, so a relay
   that handshakes but does not forward no longer strands the attempt.

Re-verified after both fixes: `leak_check_test.dart` (30),
`connection_state_test.dart` + `connection_walk_test.dart` (31) — all pass.

## 5. Pre-existing failures (not from this work)

Both fail identically with the fix reverted:

1. `test/app_smoke_test.dart` — "pressing Connect with an empty directory says
   why": looks for the text *"the live server source could not be reached"*,
   which the current message no longer uses.
2. `test/discovery_test.dart` — "publishes the servers a provider returned":
   expects `DirectoryState.fresh` where the snapshot now reports another state.

Both are in the discovery-message and snapshot-state area, which the task
explicitly puts outside the connection failure. They are reported rather than
"fixed" by rewriting the assertions.

## 6. Files changed

| File | Change |
| --- | --- |
| `packages/phantrix_platform/windows/phantrix_ovpn_helper.cpp` | **The fix.** Net-class `ComponentId` registration, scoped to this session's adapter, read back and restored; `ovpn.driver_not_registered` |
| `packages/phantrix_platform/lib/phantrix_platform.dart` | User-facing messages for the two driver codes |
| `test/windows_openvpn_adapter_test.dart` | New, 18 tests, sabotage-verified |
| `tools/diagnose_windows.dart` | Repeatable diagnostic: feed walk, profile re-check, and an `--engine` mode that proves the deployed runtime runs |
| `tools/windows/phantrix_helper_harness.cpp` | Drives the real helper over the real pipe protocol |
| `tools/windows/phantrix_adapter_probe.cpp` | Creates a real Wintun adapter, applies the registration, launches the bundled engine, restores the key — the one-elevated-click proof |
| `lib/vpn/leak_check.dart` | **Verifier fix.** Fresh `http.Client` per read so pooled sockets cannot mask a working tunnel |
| `lib/vpn/connection_controller.dart` | `walkable` now includes `leak.*`, so a non-forwarding relay is walked past |
| `docs/evidence/openvpn/WINDOWS_ROOT_CAUSE.md` | The diagnosis, with the source and registry evidence |
| `docs/evidence/openvpn/WINDOWS_LIVE_VERIFICATION.md` | Procedures A and B, runnable on either PC |

## 7. Android

No Android code was modified. The Android path is untouched: ics-openvpn builds
its `tun` through `VpnService`, which needs no registry adapter and no
`--dev-node`, so the defect could not have affected it and nothing in the fix
touches it.

*(Note added 2026-10-13: the ics-openvpn engine described here was removed from
the repository two days after this session, for licence incompatibility —
`docs/LICENSING_AUDIT.md`. The statement above is accurate for the session it
records; a current Android build has no OpenVPN engine at all.)*

| Check | Result |
| --- | --- |
| `flutter test` (`phantrix_core`, which holds the protocol and state machine) | 184 passed |
| Android sources changed in this work | none — `git status` shows only the two Windows/C++ files and the Dart bridge |

**An Android emulator or device was not attached to this machine**, so the
on-device integration tests were not run. There is no basis for claiming
Android was exercised here; there is also no change to it to exercise.
