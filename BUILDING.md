# Building Phantrix

The latest audit used Windows, Flutter 3.47.5 / Dart 3.13.4, JDK 25
(Android Studio JBR), Android Gradle Plugin 9.1.0, and Visual Studio 2022
Build Tools 17.14 with the C++ workload. Windows, web, and Android release
builds compiled; see [PROJECT_AUDIT.md](docs/PROJECT_AUDIT.md) for the exact
checks and limitations. Older dated observations below are historical evidence,
not fresh verification of every platform.

The OpenVPN 2.6.17 runtime pin has known security advisories. Do not distribute
that bundle before upgrading and validating it. A Windows build without the
runtime can compile but cannot connect.

Where a build cannot succeed in this environment, or cannot succeed at
all in the current code, this document says so instead of hoping.

---

## 1. Required toolchains

| Tool | Version | Why / where it comes from |
| --- | --- | --- |
| Flutter | 3.47.5 | Version pinned by CI and used in the latest audit |
| Dart | 3.13.4 (bundled with Flutter) | The root `pubspec.yaml` requires `sdk: ^3.13.0`; `packages/phantrix_core/pubspec.yaml` requires `^3.9.0` |
| JDK | 21 recommended, matching Android CI | Java/Kotlin bytecode targets are 17, which is not the Gradle runtime version. JDK 25 compiled the release, but the upstream integration-test Mockito/Byte Buddy tests reject Java 25 |
| Android SDK | Platform 35 | `packages/phantrix_platform/android/build.gradle.kts` sets `compileSdk = 35`; the app module uses `flutter.compileSdkVersion`. No NDK: the plugin compiles no native code |
| Gradle | 9.3.1 (via wrapper) | `android/gradle/wrapper/gradle-wrapper.properties` downloads `gradle-9.3.1-all.zip` |
| Android Gradle Plugin / Kotlin | AGP 9.1.0 / Kotlin 2.4.0 | `android/settings.gradle.kts` |
| Visual Studio 2022 | "Desktop development with C++" workload | Windows desktop only; latest checks used Build Tools 17.14 |
| Xcode | Current stable | macOS and iOS only, and only on a Mac |

`android/local.properties` in this repository points at
`sdk.dir=C:\Users\<you>\AppData\Local\Android\Sdk` and
`flutter.sdk=C:\FlutterSDK`. If your SDK or Flutter lives elsewhere,
edit that file (it is machine-local and git-ignored by convention) or set
`ANDROID_SDK_ROOT`.

---

## 2. Get dependencies

Run once, from the repository root:

```bash
flutter pub get
cd packages/phantrix_core && dart pub get && cd ../..
cd packages/phantrix_platform && flutter pub get && cd ../..
```

The root `pubspec.yaml` now depends on `phantrix_core` and
`phantrix_platform` via `path:`, so the app target compiles against both
packages directly (see ARCHITECTURE.md).

---

## 3. The domain layer: analyze and test

This is the part of the project that is complete, and the gate every
change must pass.

```bash
cd packages/phantrix_core
dart analyze      # clean as of this writing
dart test --reporter expanded
```

`dart analyze` in `packages/phantrix_platform` is also clean.

`flutter test` at the root runs the checked-in app suite in `test/`, including
state-machine, connection-flow, persistence, licensing, and rendered-UI tests.
The integration tests in `integration_test/` are separate because they require
a real device/emulator and the platform channel.

Native Windows profile/path/IPC regression tests can run without UAC or a
network route change after building the app:

```powershell
flutter build windows --release
tools/test_windows_support.ps1 -Configuration Release
tools/check_windows_build.ps1
```

The last command permits a missing runtime for a compile-only check. Distribution
checks require `-RequireOpenVpn` and a reviewed, updated runtime.

For Android JVM tests, run `gradlew.bat testDebugUnitTest --console=plain`
inside `android/` with `JAVA_HOME` pointing at JDK 21. With JDK 25 the audit
observed three failures in Flutter's `integration_test` screenshot tests:
`Java 25 (69) is not supported ... Byte Buddy ... Java 22 (66)`.
No project code or test was disabled to hide that failure. The app and platform
plugin have no Java/Kotlin unit-test sources today; a `NO-SOURCE` result is not
Android tunnel coverage.

Expected analyzer configuration:

- Root: `analysis_options.yaml` includes `package:flutter_lints/flutter.yaml`.
- `packages/phantrix_core/analysis_options.yaml`: `lints/recommended` plus
	`strict-casts`, `strict-inference`, and rules including
	`always_declare_return_types`, `avoid_dynamic_calls`, `close_sinks`,
	`comment_references`, `directives_ordering`, `valid_regexps` and
	`eol_at_end_of_file`.

Known state of `flutter analyze` at the repository root as of this writing:
**no issues found**, in the root app and in both packages. Do not paper over a
mass of diagnostics with `// ignore:` comments; a real error after dependency
resolution is the first failure to fix, and later errors may be cascades from
it.

---

## 4. Android

### 4.1 Run on a device or emulator

```bash
flutter devices
flutter run -d <android-device-id>
```

Requirements and permissions already declared in
`packages/phantrix_platform/android/src/main/AndroidManifest.xml`:

- `android.permission.INTERNET` — the app fetches the public relay list over
	HTTPS; it is declared in the plugin manifest because that is where the
	app inherits it from

Nothing else is declared, and that is the point: there is no tunnel service in
this build, so there is no `BIND_VPN_SERVICE`, no foreground service type, no
notification permission and no boot receiver to go with one. A manifest that
kept them would ask the user to grant capabilities the app cannot use.

### 4.2 Regenerate the plugin registrant before release builds

`flutter test integration_test` generates
`android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java`
with the integration-test plugin registered in it. A later plain
`flutter build apk` reuses that file if its timestamp looks fresh, and the
release compile then fails on `package dev.flutter.plugins.integration_test
does not exist`. The file is generated and untracked, so the fix is deletion,
not editing — and the reproducible procedure is `flutter clean` before any
release build that follows an integration-test run:

```powershell
Remove-Item android\app\src\main\java\io\flutter\plugins\GeneratedPluginRegistrant.java -Force -ErrorAction SilentlyContinue
flutter clean
flutter build apk --release --split-per-abi
```

This bit twice in one day, which is why it is written down rather than left
as tribal knowledge: a release artifact that cannot be rebuilt from a clean
checkout on demand is not a release artifact.

**Verified 2026-10-11 on Flutter 3.47.0 / Dart 3.13.0:** a `flutter build apk
--release --split-per-abi` following an integration-test run now regenerates
`GeneratedPluginRegistrant.java` on its own — the release compile succeeds and
the file registers only `PhantrixPlugin`, with no integration_test reference.
The delete-then-clean procedure above is therefore a **fallback for older
toolchains**, not a required step on this one; keep it in mind if a release
build fails on `package dev.flutter.plugins.integration_test does not exist`.

**Audit caveat on Flutter 3.47.5:** do not run test generation and Android
release generation concurrently. They share the generated registrant, and an
overlapping run reproduced this failure. Removing only the untracked generated
registrant and rerunning `flutter build appbundle --release` serially succeeded;
no full clean or source change was needed.

### 4.3 Dependency verification

`android/gradle/verification-metadata.xml` pins `sha256` values for every Gradle
artifact. A stale pin fails the build with `Dependency verification failed`.
If you bump a dependency, regenerate the pins (`gradlew --write-verification-metadata sha256`)
and review the diff; do not disable the check. Verification stays fully
enabled — no `trusted-artifacts` escape hatch is added.

### 4.4 Android signing for release

`android/app/build.gradle.kts` reads an optional `android/key.properties` and
uses it to build a `release` signing config. **When that file is absent the
build still succeeds, falls back to the debug key, and prints a warning saying
so.** That is deliberate: "no upload key" is a configuration state, not a code
defect, and failing every local release build over it would only teach people
to ignore the warning.

To produce a publishable build:

1. Create an upload keystore:
	```bash
	keytool -genkeypair -v -keystore %USERPROFILE%\phantrix-upload.jks ^
		-keyalg RSA -keysize 4096 -validity 10000 -alias upload
	```
2. Create `android/key.properties`. It is listed in `.gitignore`, along with
	`*.jks` and `*.keystore`, so an accidental `git add .` cannot publish it:
	```properties
	storeFile=C:/Users/<you>/phantrix-upload.jks
	storePassword=<keystore password>
	keyAlias=upload
	keyPassword=<key password>
	```

Then:

```bash
flutter build apk --release --split-per-abi
flutter build appbundle --release
```

Verify which key actually signed the result rather than trusting the config:

```powershell
$env:JAVA_HOME = 'C:\Program Files\Android\Android Studio\jbr'
& "$env:LOCALAPPDATA\Android\Sdk\build-tools\36.0.0\apksigner.bat" verify --print-certs `
  build\app\outputs\flutter-apk\app-arm64-v8a-release.apk |
  Select-String 'certificate DN'
```

`CN=Android Debug` means the build is not distributable. Play App Signing
takes the upload key and re-signs with a key it holds; losing the upload
keystore is recoverable through Google, losing the app signing key is not.

Release builds are minified (`isMinifyEnabled`, `isShrinkResources`) with keep
rules in `android/app/proguard-rules.pro` for what the engine looks up by name.
Keep the R8 mapping file from every release
— without it a crash report from a shipped build is unreadable:

```
build/app/outputs/mapping/release/mapping.txt
```

### 4.5 What the Android build does and does not give you

`flutter build apk --release` succeeds and produces a **minified, installable**
artifact. Confirm the permission set is still the small one before trusting it:

```powershell
$aapt = "$env:LOCALAPPDATA\Android\Sdk\build-tools\36.0.0\aapt2.exe"
& $aapt dump badging build\app\outputs\flutter-apk\app-arm64-v8a-release.apk |
  Select-String "uses-permission"
```

Expect exactly this, and nothing else:

```
android.permission.INTERNET
```

Anything more is a finding worth stopping for: this build declares no VPN
service permission, no foreground service type, no notification permission and
no boot receiver. There is also no analytics SDK, no location, no contacts, no
storage and no `QUERY_ALL_PACKAGES`.

**What the build gives you:** a real, installable app that lists servers and
refuses to connect to any of them, saying why — there is no OpenVPN engine on
Android, and the licence review in `docs/LICENSING_AUDIT.md` explains why the
only candidate could not be shipped. No cryptography is implemented in this
repository, on any platform.

**What it does not give you:** a tunnel of any kind. See §4.6 and the README's
platform table.

### 4.6 Proving a connection on a device

It cannot be done in this build: with no engine on Android, the app declines
every relay with an explanation instead of attempting a connection.

What is on record, from before the app became OpenVPN-only: 4 app tests ran on
an Android 14 x86_64 emulator and passed (`flutter test integration_test -d
<device-id>`), exercising the real app against the real platform channel — the
first-run flow, every screen's layout, and a connect control that reported
honestly instead of claiming "Connected". The 15 engine tests that loaded
`libwg-go.so` went away with the WireGuard engine, and no test starts a tunnel
on Android today.

If an OpenVPN engine is ever added for Android, it needs its own on-device
suite before this section can claim anything again.

---

## 5. iOS

**Status: source complete in `packages/phantrix_platform/apple/`; not
buildable here.** A real `NEPacketTunnelProvider`, a
`NETunnelProviderManager` wrapper, the configuration mapper, the Flutter
bridge, entitlements and the extension Info.plist all exist. None of it
has been **compiled**, because that needs Xcode and a Mac, and none of it
has been **signed**, because that needs an Apple Developer account.

`pubspec.yaml` deliberately does **not** declare `ios`. Declaring a
platform whose source does not compile produces either a build failure
or a stub answering "not supported" — a placeholder presented as a
backend. The Dart layer reports iOS as unsupported, which is true.

### To build it, on a Mac

1. Add the Swift package `https://git.zx2c4.com/wireguard-apple` and its
   `WireGuardKit` product to the app and extension targets.
2. Create the `WireGuardGoBridgeiOS` external build target — `make` in
   `Sources/WireGuardKitGo`, `SDKROOT=iphoneos` — and make it a
   dependency of the extension. Swift Package Manager cannot build
   `libwg-go` itself.
3. Create the *Packet Tunnel* extension target,
   `$(PRODUCT_BUNDLE_IDENTIFIER).network-extension`, deployment target
   **iOS 15.0+**, and copy `apple/Sources/Extension/` into it with
   `apple/Sources/Shared/`.
4. Apply `apple/Entitlements/PhantrixNetworkExtension_iOS.entitlements`
   to the extension and `apple/Sources/Extension/Info.plist` as its
   Info.plist.
5. Set `com.phantrix.ios.app_group_id` in the app's Info.plist and add
   the **same** `com.apple.security.application-groups` value plus
   `com.apple.developer.networking.networkextension`
   (`packet-tunnel-provider`) to the app's entitlements.
6. Add `apple/Sources/App/` and `apple/Sources/Shared/` to the app
   target.
7. **Then** declare the platform in the plugin pubspec.

`packages/phantrix_platform/apple/README.md` is the authoritative version
of that list, including the signing and provisioning requirements.

```bash
flutter build ios --debug     # after the above
```

Not verifiable in the Windows environment this document was written in.

---

## 6. macOS

**Status: source complete in `packages/phantrix_platform/apple/`; not
buildable here.** The same extension and app-side sources serve macOS;
`apple/Entitlements/PhantrixNetworkExtension_macOS.entitlements` is the
macOS variant, which additionally carries the app sandbox and the
client/server network entitlements.

macOS is not a copy of iOS: the app group is
`$(DEVELOPMENT_TEAM).group.$(APP_ID_MACOS)` (team-qualified), the
extension bundle sits in `builtInPlugInsURL`, and the keychain item is
wrapped in a `SecAccess` naming both trusted applications. All of that is
in the sources.

The macOS runner's existing `DebugProfile.entitlements` and
`Release.entitlements` contain only the app sandbox and are **not**
sufficient — the network-extension and app-group keys must be added as
described in `apple/README.md`.

```bash
flutter build macos --debug   # after the above, on a Mac
```

Not verifiable in the Windows environment this document was written in.

---

## 7. Windows

```powershell
# Required for the built-in VPN Gate OpenVPN servers. Downloads only the
# pinned runtime files and verifies their SHA-256 hashes before installation.
powershell -NoProfile -ExecutionPolicy Bypass -File tools\fetch_openvpn_bundle.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tools\fetch_openvpn_bundle.ps1 -VerifyOnly

flutter build windows --release
```

The commands above use the Windows PowerShell that ships with Windows. If you
have PowerShell 7 installed you can use `pwsh -NoProfile -File ...` instead;
the CI workflow does. If `pwsh` is "not recognized", you do not have PowerShell 7
and should use the `powershell` form above.

A Windows build without the fetched runtime can still compile, but it will
report OpenVPN as unavailable and therefore cannot connect to the built-in
VPN Gate relay list. Run the fetch/verification steps before **any** Windows
run used to test VPN Gate, not just before release builds. If you previously
configured or built Windows without the runtime, run `flutter clean` after
fetching so CMake regenerates the bundle file list. The GitHub Windows workflow
fetches and verifies the runtime automatically.

**Visual Studio is required and cannot be skipped.** Flutter's Windows
embedding is compiled with the MSVC toolchain from Visual Studio (not the
VS Code C/C++ extension, not MinGW, not ClangCL). Without it you get
"Unable to find suitable Visual Studio toolchain" or CMake failures, and
there is no supported workaround. **The Windows build has been verified
here** with Visual Studio Community 2026 and produces
`build/windows/x64/runner/Release/phantrix.exe` (debug builds land under
`build/windows/x64/runner/Debug/`).

The Windows tunnel backend drives one real engine and implements none of it:

- **OpenVPN** through the official **OpenVPN 2.6 community binaries** plus
  the **wintun** driver, fetched and hash-verified by
  `tools/fetch_openvpn_bundle.ps1` (pinned SHA-256, verified before
  extraction) and driven by a small `requireAdministrator` helper
  (`phantrix_ovpn_helper.exe`) that the app launches via `runas`. The app
  itself never runs elevated. The helper spawns `openvpn.exe` with fixed
  arguments (`--config`, `--windows-driver wintun`, `--status`, `--log`),
  supervises it, and stops it gracefully (console control event first,
  `TerminateProcess` as fallback). The two sides talk over a named pipe
  with an explicit Medium-integrity DACL; see
  `docs/OPENVPN_BACKEND_VERIFICATION.md` §4 for what was verified and what
  was not run.

Two consequences the user must know about, both surfaced as errors rather
than worked around:

- **Running a tunnel needs Administrator rights.** The prompt comes from
  the helper's `runas` launch, which the user can also decline (reported as
  a failure, never retried silently). This code never elevates itself
  beyond that, never installs a driver outside the OpenVPN bundle flow, and
  never alters firewall rules.
- **There is no kill switch on Windows.** When the tunnel drops, traffic
  can leave over the normal network until the app reconnects. The app says
  so in Settings instead of claiming protection it does not have.

An OpenVPN profile (which carries the relay's certificates) is written to a
session directory with an explicit owner-only DACL and removed with the whole
directory on every stop path; a profile that cannot be secured is refused
rather than connected with.

---

## 8. Linux

```bash
flutter build linux --debug
```

Requires `clang`, `cmake` and `ninja-build` (Debian/Ubuntu:
`sudo apt install clang cmake ninja-build libgtk-3-dev pkg-config`),
plus `wireguard-tools` for the tunnel itself.

**The Linux plugin is not buildable in the Windows development
environment**, so it is compiled by CI instead:
`.github/workflows/linux.yml` runs on Ubuntu 24.04, installs those
prerequisites, downloads Flutter 3.47.0 (SHA-256 verified), and runs
`flutter build linux --debug` — which is what compiles
`packages/phantrix_platform/linux/phantrix_plugin.cc`.

The backend is real: it detects `wg`/`wg-quick` and kernel support,
stages the configuration as a root-owned 0600 file, brings the interface
up with `wg-quick up` through `pkexec`, and tears it down with
`wg-quick down` on disconnect **and on failure**. Privileged commands go
out as argument vectors via `posix_spawnp`, never through a shell, and
the workflow fails if `std::system` reappears.

It has **never been run against a live system** — a compile is not a
running tunnel. The manual runtime procedure, including how to supply a
peer without committing a credential, is in
`docs/LINUX_RUNTIME_TESTING.md`. No CI job elevates anything or changes
host networking.

---

## 9. Web

```bash
flutter build web
flutter run -d chrome
```

The web target builds as a normal Flutter web app, but **there is no VPN
functionality in a browser** and none is claimed: `PlatformCapabilities.web`
in `packages/phantrix_platform/lib/phantrix_platform.dart` reports every
capability as unsupported with the limitation text "A browser cannot
protect traffic outside itself. A system-wide client on Windows, macOS,
Linux, Android or iOS is required." `startTunnel` on web cannot succeed.
Do not add UI that suggests otherwise.

---

## The app icon

`assets/icon.png` is the single source of truth for the Phantrix mark —
1024×1024, and the same drawing the app renders in its own chrome (see
`VgLogo` in `lib/ui/components/brand.dart`). Every platform keeps a generated
copy of it in the shape that platform's toolchain expects, and all of them are
rebuilt from that one file:

```bash
powershell -ExecutionPolicy Bypass -File tools\generate_app_icons.ps1
```

The script regenerates, using `System.Drawing` only (no ImageMagick, no
Python, nothing to install):

| Platform | Output |
| --- | --- |
| Android | `mipmap-{mdpi,hdpi,xhdpi,xxhdpi,xxxhdpi}/ic_launcher.png` — 48 to 192px |
| iOS | `AppIcon.appiconset/Icon-App-*` — the full 20/29/40/60/76/83.5/1024 set |
| macOS | `AppIcon.appiconset/app_icon_{16…1024}.png` |
| Windows | `windows/runner/resources/app_icon.ico` — 7 sizes, PNG-encoded entries |
| Web | `favicon.png`, `icons/Icon-{192,512}.png`, plus maskable variants inset to the launcher safe zone |

Small sizes are produced by repeated halving rather than a single-step resize,
because one step from 1024 to 16 discards most of the detail and leaves the
mark unreadable in a taskbar. Run it again after any edit to
`assets/icon.png`; the copies are checked in, so a stale icon is a visible diff
in review.

---

## 10. Test summary

**Patch verification note (2026-10-10):** The environment used to prepare this
patch does not have Flutter, Dart, PowerShell, or a Windows runner installed.
The changes therefore have not been run through `flutter analyze`, Dart tests,
a Windows build, or a live tunnel test here. The results below are historical
baseline evidence from before these edits; run the commands again on the
appropriate toolchain before treating them as validation of this patch. The
new cache-bypass, lazy-profile-validation, automatic profile-fallback, and
preflight-timeout tests are not claimed as passing until executed.

| Command | What it runs | Status on this checkout |
| --- | --- | --- |
| `cd packages/phantrix_core && dart test` | 197 domain tests across protocol parsing, validators, providers, scoring, state machine, redaction, fingerprints, full-tunnel repair, OpenVPN host validation | **197 pass** |
| `cd packages/phantrix_core && dart analyze` | Analyzer with strict modes | No issues found |
| `cd packages/phantrix_platform && dart analyze` | Plugin Dart code | No issues found |
| `cd packages/phantrix_platform && flutter test` | 22 bridge tests: state-machine wire round trip, `TunnelRequest` field presence and JSON encoding, the `PlatformEvent` handshake-versus-established distinction, and capability honesty | **22 pass** |
| `cd packages/phantrix_platform && dart analyze` | Plugin Dart code | No issues found |
| `flutter analyze` (root) | App + both packages | No issues found |
| `flutter test` (root) | 250 host tests: discovery merge/sort/dedup, HTTPS fetcher rules, server resolution and non-silent fallback, leak verification including captive-portal and stale-handshake attacks, connection state machine including a stale-callback race, localisation, privacy copy, widget semantics, whole-app smoke tests at 1x and 2x text scale | **250 pass**, 1 skipped |
| `flutter test test/ui_screenshots_test.dart` | Renders the real widget tree to `docs/evidence/ui/` at four window sizes, both themes, and 1.6x text scale; fails on any overflow |
| `flutter test integration_test/ -d <device>` | **On-device** app tests: the real app, real platform channel, real OS | **4 pass** on Android 14 x86_64, recorded before the app became OpenVPN-only. Using the connect control with no reachable server reports honestly and never shows "Connected" |
| `flutter build apk --release --split-per-abi` | R8-minified release APKs. See 4.5: the app builds and installs, and has no tunnel engine to reach |
| `flutter build web --release` | Web build | **Succeeds** |
| `flutter build windows --release` | Windows release bundle (37.5 MB): `phantrix.exe`, `phantrix_platform_plugin.dll`, `phantrix_ovpn_helper.exe`, and the OpenVPN bundle (`openvpn.exe`, `wintun.dll`, the OpenSSL DLLs). 40 artifact checks pass on the built binary |
| `flutter build ios` | iOS build | **Not attempted**: requires Xcode, a Mac and Apple signing. A complete `NEPacketTunnelProvider` and plugin bridge exist in `packages/phantrix_platform/apple/`; see the manual steps in its README |
| `flutter build macos` | macOS build | **Not attempted**: requires Xcode. The extension and plugin source exist in `packages/phantrix_platform/apple/`; signing and provisioning remain |
| `flutter build linux` | Linux build | **CI only** — no Linux toolchain here. `.github/workflows/linux.yml` compiles the plugin and app, and asserts the plugin registers and exports its entry point |
| `powershell -File tools/check_windows_build.ps1` | Built-artifact invariants: no shell, no command chaining, the profile directory is private, no embedded private key |

### Continuous integration

Four workflows, each proving something the others cannot.

| Workflow | Runner | What it establishes |
| --- | --- | --- |
| `verify.yml` | Ubuntu 24.04 | `flutter analyze --fatal-infos`, formatting, and every test in all three packages. Uploads the rendered UI |
| `android.yml` | Ubuntu 24.04 | The Kotlin bridge compiles and the app tests pass; a minified App Bundle and per-ABI APKs are produced. There is no tunnel engine to compile on Android any more |
| `linux.yml` | Ubuntu 24.04 | `phantrix_plugin.cc` compiles and links; the registrant calls the entry point and `nm -D` shows the `.so` exports it |
| `windows.yml` | Windows 2022 | The C++ backend compiles and links, and 40 checks pass **on the built binary** |

The Linux workflow additionally **fails the build** if `std::system` reappears
in the Linux backend, or if a shell metacharacter is introduced alongside it.
Comments are stripped before the check so that documenting the rule does not
trip it.

The Windows workflow's checks run against `phantrix_platform_plugin.dll` as
built, not against the source. Each corresponds to a bug this repository has
actually had:

| Check | The bug it catches |
| --- | --- |
| no `cmd.exe`, `powershell.exe`, `wscript`, `cscript` | the backend shelling out, which would let a configuration value reach a command interpreter |
| no `&&`, `\|\|`, `2>&1`, `\| tee` | command concatenation, the other half of shell injection |
| the helper passes `openvpn.exe`, `--config`, `--status` and `--windows-driver wintun` | the CLI contract silently changing, turning connect into a confusing runtime failure |
| no `BEGIN PRIVATE KEY` in the binary | a shipped key, which would be a key for everybody who downloads the app |
| every bridge method name present | a rename breaking the plugin at run time rather than at build time |

**No workflow runs a tunnel.** None has a reachable peer it is allowed to use, so
a green run says nothing about whether traffic routes, and none of them claims
otherwise. Linux needs `CAP_NET_ADMIN`, Windows needs the helper and an
administrator token, and Android needs an engine before a device could help —
none of which a CI job should have.

Third-party actions are pinned to immutable commit SHAs, each resolved through
the GitHub API and checked against the release commit it names
(`actions/checkout` v4.2.2, `actions/cache` v4.3.0, `actions/setup-java` v5,
`gradle/actions` v5, `actions/upload-artifact` v4.6.2). Flutter is installed by
`tools/install_flutter.sh` from Google's own bucket with a **SHA-256
verification**, not by a third-party action, because an action that chooses
which SDK to fetch is an action that could choose a tampered one. Every job
holds `permissions: contents: read` only, and no job elevates itself.

### The three test tiers, and what each can prove

They are deliberately separate, because they have very different power:

| Tier | Where it runs | Command | What it can prove | What it cannot |
| --- | --- | --- | --- | --- |
| **Unit / widget** | Host VM | `dart test`, `flutter test` | Protocol parsing, validation, scoring, the state machine, the verification gate, layout | Anything about the operating system |
| **On-device app** | Android 14 emulator | `flutter test integration_test/ -d <id>` | The real app starts, the first-run flow works, every screen lays out, and Connect never claims a false success | That a tunnel carries traffic |

Only the on-device tier touches an operating system, and it cannot prove traffic
routing. On Windows, the live tunnel recorded in `docs/evidence/openvpn/` is the
one piece of evidence that a connection works; everything else is a claim about
the code. A test that asserted a successful handshake without a peer would be
asserting something nobody checked.
