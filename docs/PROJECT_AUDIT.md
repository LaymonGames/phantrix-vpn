# Project audit

## Outcome and scope

The audit fixes concrete validation, verification, lifecycle, persistence, and
build-check defects. **It does not approve this project for a security release.**
The Windows runtime pin has known upstream security advisories, and DNS/IPv6
leak prevention and a strict kill switch are not established.

Scope included the Flutter application, both Dart packages, native platform
sources, dependency lockfiles, build/CI scripts, persistence, HTTP ingestion,
configuration parsing/serialization, and security/privacy claims. Checks ran on
Windows with Flutter 3.47.5, Dart 3.13.4, Visual Studio 2022 Build Tools 17.14,
Android SDKs, and Android Studio JBR 25.0.3. This is a source/build/test audit,
not a formal penetration test or an exhaustive proof that no bugs remain.

Historical live-tunnel evidence elsewhere in this repository is not a live test
of these changes. No UAC elevation, tunnel connection, firewall modification, or
packet-capture experiment was performed during this audit.

Before publication, the audit branch was rebased onto GitHub `main` at
`8f72ad8`, preserving its licensing/credits work and 1.0.1 version updates.
Application tests and all three release builds were rerun on that integrated
tree. The shared destination branch was not changed.

## Fixed findings, in priority order

### High: elevated Windows profile and file boundary

- The helper previously checked only a 64 KiB prefix, while the engine read the
  complete file. It now rejects oversized profiles and validates all bytes.
- A denylist alone permitted unknown engine directives. The helper now allows
  only the normalized client/TUN format, inline certificate/key blocks, fixed
  routing options, and server-certificate verification. External paths,
  scripts, credential prompts, unsupported directives, malformed blocks, and
  embedded NUL bytes are rejected.
- String-prefix path checks were insufficient against traversal and replacement.
  Fixed session filenames, reparse-point/hardlink checks, and held directory and
  profile handles now protect the checked files while the engine uses them.
- Early rejection could use an uninitialized writer lock. The helper now uses
  a statically initialized SRW lock. Pipe writes use actual overlapped I/O;
  frames enforce version, type, size, and complete payload consumption.

Implementation: [native support](../packages/phantrix_platform/windows/phantrix_ovpn_support.cpp),
[helper](../packages/phantrix_platform/windows/phantrix_ovpn_helper.cpp).
Executable regressions cover profile policy, message frames, real file locks,
traversal, and oversized malicious tails:
[native tests](../packages/phantrix_platform/windows/phantrix_ovpn_support_test.cpp).
These run without admin rights through
[test_windows_support.ps1](../tools/test_windows_support.ps1), including in CI.

### High: OpenVPN server authentication and policy fidelity

Serialization dropped server certificate-role verification, explicit name
pinning, TLS options, per-remote transport, and key direction. It could also
replace negotiated ciphers with a fallback and silently discard `none`.

The normalized profile now always includes `remote-cert-tls server`, preserves
supported pinning/TLS/transport options, and distinguishes negotiated ciphers
from fallback. Validation rejects broken fallbacks, non-client transport modes,
malformed addresses/ports, and unsafe policy values. Default remote port 1194
and global port directives no longer depend on transport/directive order.

Implementation: [OpenVPN parser/serializer/validator](../packages/phantrix_core/lib/src/protocol/openvpn/).
Tests: [protocol regressions](../packages/phantrix_core/test/protocol/ovpn_test.dart)
and [address parsing](../packages/phantrix_core/test/protocol/address_cidr_test.dart).

Compatibility consequence: old relays with certificates lacking server usage
may now fail. Do not weaken certificate verification to restore compatibility;
validate supported relays with a current engine.

### High: false-positive connection verification

A missing pre-tunnel baseline could still verify successfully. Textually
different spellings of the same IPv6 address, a change of IP family, or future
handshake timestamps could also be misclassified.

Verification now requires a baseline, a recent non-future handshake, and a
changed address in the same family, comparing parsed bytes. Default echo
endpoints use IPv4 consistently and responses are capped at 4 KiB. Failure to
measure is failure to verify. **Success measures the probed IPv4 route, not
DNS/IPv6 protection or every application's routing.**

Implementation/tests: [LeakCheck](../lib/vpn/leak_check.dart),
[leak checks](../test/leak_check_test.dart).

### High: manifest authentication and trust labels

Unsigned entries could grant themselves project/community trust, and an invalid
configured signature did not fail the refresh. HTTP line splitting also changed
the exact body used to verify detached signatures.

Configured signing now fails closed, signature endpoints require HTTPS, and
unsigned entries retain unknown trust. Manifest content cannot attest to its own
signature. Exact body text is preserved, including CRLF and the final newline.
Malformed metadata is skipped safely; unsupported versions, expired entries,
and duplicate identifiers no longer crash or mismatch metadata/configuration.

Implementation: [manifest provider/schema](../packages/phantrix_core/lib/src/providers/manifest/),
[HTTP fetcher](../lib/net/app_http_fetcher.dart).
Regressions cover hostile field types, trust spoofing, signature failure, expiry,
duplicate IDs, and exact response bytes.

### Medium: lifecycle, stop errors, and persistence recovery

- Stop errors were ignored while the UI claimed disconnection. They now remain
  visible, retain session context, and prevent replacement of a tunnel whose
  stop was not confirmed.
- Cancelled preflight/native-launch continuations cannot overwrite a replacement
  attempt. Launch grace keeps a real deadline. Waiting callers can receive a
  cancellation outcome even while native launch is pending.
- Disposed controllers/bridges ignore late events and release subscriptions.
  Capabilities are read live instead of permanently caching missing-engine or
  system-lockdown state.
- A failed settings write poisoned the write queue. Later writes now recover,
  ordinary temporary files are cleaned up, and asynchronous save failures are
  caught. Profile-cache replacement no longer deletes the good file first.

Implementation/tests: [connection controller](../lib/vpn/connection_controller.dart),
[platform bridge](../packages/phantrix_platform/lib/src/phantrix_platform.dart),
[store](../lib/storage/app_store.dart), [connection tests](../test/connection_state_test.dart),
[persistence tests](../test/app_store_test.dart).

### Build checks and documentation

- The formatting gate no longer hides tool errors with `|| true`.
- Owned Dart formatting was corrected; the platform package declares the Flutter
  lint dependency required by its inherited analysis configuration.
- Bundle verification/download failures no longer abort before their intended
  fallback/cleanup; MSI paths with spaces are quoted.
- Windows binary inspection no longer infers missing method handlers from
  compiler-optimized string literals, or mistakes the path to VPN Gate's public
  `vpn`/`vpn` file for exposed user credentials. Native tests exercise rejection
  behavior; binary scans are documented as smoke checks, not security proofs.
- Security/privacy/build documents now distinguish preferences from enforcement,
  disclose cached public client keys and retained raw native logs, and remove
  obsolete Android service/Windows LocalSystem claims.
- The upstream notices freshness gate exposed stale platform-version metadata
  and an environment-dependent OpenVPN licence fallback. The existing full
  binary notice was preserved as a vendored snapshot, not deleted/replaced with
  a shorter source COPYING file. Identical normalized notices now use a stable
  source label with or without the optional runtime; a changed bundle notice
  remains visible. Regression coverage includes absent, identical, and changed
  bundle notices. Review this snapshot again when upgrading the runtime.

## Verification

| Check | Observed result |
| --- | --- |
| `flutter analyze --fatal-infos --fatal-warnings` | Passed, no issues |
| Core `dart analyze` | Passed |
| Platform `flutter analyze --fatal-infos --fatal-warnings` | Passed |
| Owned Dart `dart format --output=none --set-exit-if-changed` | Passed, 200 owned files including generated notices, plus the notices generator (201 total) |
| App `flutter test --no-pub --reporter expanded` | 277 passed, 1 POSIX-permission test skipped on Windows |
| Core `dart test --reporter expanded` | 210 passed |
| Platform `flutter test --no-pub --reporter expanded` | 27 passed |
| Windows native support test executable, Debug and Release | Passed |
| `flutter build windows --debug` / `--release` | Passed; OpenVPN runtime absent |
| `flutter build web --release` | Passed; no browser runtime test |
| `flutter build appbundle --release` | Passed; debug signing fallback, no Android VPN engine |
| `tools/check_windows_build.ps1` | Passed without `-RequireOpenVpn`; runtime check skipped |
| `dart run tools/generate_third_party_notices.dart --check` | Passed, 96 entries and 86 licence texts |
| PowerShell parser and mocked bundle failure paths | Passed; no network download/extraction performed |
| OSV query of all three Pub lockfiles | No advisories returned for 79 unique hosted package/version pairs; excludes native runtime/SDK dependencies |
| Android `gradlew.bat testDebugUnitTest --console=plain` | Failed: 3 Flutter SDK `integration_test` screenshot tests; Byte Buddy rejects JDK 25 |
| Android `:app:testDebugUnitTest :phantrix_platform:testDebugUnitTest` | Successful tasks, both `NO-SOURCE`; not native unit-test coverage |
| `git diff --check` | Passed |

The Android all-project JVM failure is not hidden or fixed by disabling tests.
The installed Byte Buddy supports Java class versions only through Java 22,
while this machine uses Java 25. Re-run with JDK 21, matching Android CI.
No suitable JDK 21 installation was found in the inspected standard locations.

An overlapping test/release run also left a test-generated Android plugin
registrant referencing `integration_test`, which is absent from release
dependencies. Removing only that untracked generated file and rerunning
`flutter build appbundle --release` serially succeeded (51.8 MB AAB). Do not
overlap Flutter/Gradle test generation with Android release generation. The
final Windows build had a nonfatal MSBuild temporary-response-file cleanup
warning; compilation, native tests, and artifact inspection still succeeded.

## Unresolved and required decisions

### P0 — update the Windows runtime before distribution

[fetch_openvpn_bundle.ps1](../tools/fetch_openvpn_bundle.ps1) still pins
**OpenVPN 2.6.17**. The upstream
[CVE-2026-40215 advisory](https://community.openvpn.net/Security%20Announcements/CVE-2026-40215)
lists 2.6.0–2.6.19 as affected by a TLS-session race that can leak previous
handshake packet data. Later maintained releases include additional fixes; use
the [upstream release history](https://community.openvpn.net/ReleaseHistory)
and [security announcements](https://community.openvpn.net/Security%20Announcements).
This audit does not claim every advisory is exploitable in this client.

Choose and validate a maintained release line, official archive and extracted
file hashes, bundled DLL/driver versions, notices/licences, and live helper
compatibility together. The pin was not replaced with an unverified binary or
guessed hashes. The runtime is absent locally, so the compiled Windows bundle
cannot currently establish a tunnel. CI still fetches the old pinned runtime;
do not treat a green artifact job as release approval.

### P1 — protection gaps and native failure handling

- **Kill switch/DNS/IPv6:** no strict traffic-blocking kill switch exists.
  Windows does not implement the requested custom DNS/MTU/host IPv6 blocking.
  `block-ipv6` only blocks traffic entering the TUN device, not the physical
  adapter. Packet-level DNS/IPv6 and drop/reconnect tests are required.
  Implementing OS enforcement is separate product/backend work; do not advertise
  the preferences or changed IPv4 probe as these guarantees.
- **Windows threading/child lifetime:** engine state includes plain booleans
  shared across threads, and bounded joins can proceed into cleanup without
  confirming thread exit. The plugin can terminate the helper without a
  kill-on-close job containing `openvpn.exe`; a helper crash/forced termination
  can therefore leave a child behind. Resolve ownership/synchronization and
  job-object containment, then fault-test kill, cancellation, sleep, reconnect,
  and teardown. See [engine](../packages/phantrix_platform/windows/phantrix_ovpn_engine.cpp),
  [engine state](../packages/phantrix_platform/windows/phantrix_ovpn_engine.h),
  and [plugin teardown](../packages/phantrix_platform/windows/phantrix_windows_plugin.cpp).
- **Unbounded platform waits:** pending native launch now releases cancelled
  outcome waiters, but `stopTunnel`, capabilities, permission, and `_lastStop`
  waits are not universally cancellable/bounded. A hung native stop can still
  prevent a later attempt. A timeout must not falsely declare a tunnel stopped.
- **No fresh live tunnel:** needs explicit approval to elevate/change network
  routes, a reviewed updated runtime, and a permitted test endpoint. Recheck
  certificate-role compatibility and confirm teardown at the OS/process level.

### P2 — platform coverage, signing, retention, and tooling

- Android has no tunnel engine. Its AAB compiles but is debug-signed without
  `android/key.properties`; supply release credentials locally, never in chat or
  committed files. Built-in Kotlin migration is still needed for future Flutter/
  AGP versions; current builds emit deprecation warnings.
- Linux WireGuard code is inert for this OpenVPN-only app and expects a
  different bridge request shape. Apple code is unwired/uncompiled. Neither
  platform was built/run here. No Android device/emulator or browser was
  available; integration tests were not run.
- The profile cache holds public-feed shared keys in plaintext/base64. Raw
  Windows logs retain connection metadata, bypass the Dart redactor, and are
  not removed by the in-app clear-log action. Decide retention/clear-data UX
  before claiming all local data is cleared. POSIX permission-command failures
  in the Dart store remain best effort.
- A settings-save failure is logged but has no user-facing persistence warning.
  Feed profiles above the helper's 64 KiB limit are safely rejected rather than
  supported; the cache permits larger entries. Signed-manifest expiry is checked,
  but a full anti-rollback/key-rotation policy remains deployment work.
- OSV's Pub lookup is not a full native/Gradle/SDK SBOM vulnerability scan.
  Passing static/unit/build checks does not establish security of those
  dependencies or a complete real-world VPN workflow.
