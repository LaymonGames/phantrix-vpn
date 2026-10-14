# Building Phantrix

Everything here was verified against the repository on a Windows machine
with Flutter 3.47.0 / Dart 3.13.0, JDK 25 (Android Studio JBR),
Android Gradle Plugin 9.1.0 and Visual Studio Community 2022 (18.10) with
the C++ workload. Commands are given for `cmd`/PowerShell; they are the
same on macOS and Linux.

Where a build cannot succeed in this environment, or cannot succeed at
all in the current code, this document says so instead of hoping.

---

## 1. Required toolchains

| Tool | Version | Why / where it comes from |
| --- | --- | --- |
| Flutter | 3.47.0 or newer | `flutter --version` on this machine reports 3.47.0, stable |
| Dart | 3.13.0 (bundled with Flutter) | The root `pubspec.yaml` requires `sdk: ^3.13.0`; `packages/phantrix_core/pubspec.yaml` requires `^3.9.0` |
| JDK | 17 | `android/app/build.gradle.kts` and `packages/phantrix_platform/android/build.gradle` both set `sourceCompatibility`/`targetCompatibility` and `jvmTarget` to 17 |
| Android SDK | Platform 35, plus NDK | `packages/phantrix_platform/android/build.gradle` sets `compileSdk = 35`, `ndkVersion = flutter.ndkVersion`; the app module uses `flutter.compileSdkVersion` |
| Gradle | 9.3.1 (via wrapper) | `android/gradle/wrapper/gradle-wrapper.properties` downloads `gradle-9.3.1-all.zip` |
| Android Gradle Plugin / Kotlin | AGP 9.1.0 / Kotlin 2.4.0 (app build) | `android/settings.gradle.kts`. Note: `packages/phantrix_platform/android/build.gradle` still pins AGP 8.7.2 and Kotlin 2.0.21 in its own `buildscript` block; the plugin-loader build is the one that matters when building the app |
| Visual Studio 2022 | "Desktop development with C++" workload | Windows desktop only. Windows builds were verified with Visual Studio Community 2022, as stated at the top of this document |
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
dart test         # 184 core tests, all passing as of this writing
```

`dart analyze` in `packages/phantrix_platform` is also clean.

`flutter test` at the root runs the checked-in app suite in `test/`, including
state-machine, connection-flow, persistence, licensing, and rendered-UI tests.
The integration tests in `integration_test/` are separate because they require
a real device/emulator and the platform channel.

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

- `android.permission.INTERNET`
- `android.permission.BIND_VPN_SERVICE` — a
	signature-level permission, so only the OS can bind the service; it is
	not capped by `maxSdkVersion`, and that is what stops other apps
	starting our tunnel
- `android.permission.FOREGROUND_SERVICE` and
	`FOREGROUND_SERVICE_SPECIAL_USE`
- `android.permission.POST_NOTIFICATIONS` (the ongoing tunnel
	notification)
- `android.permission.RECEIVE_BOOT_COMPLETED` (autostart support)

The tunnel service itself is declared `android:exported="false"` with
`android:permission="android.permission.BIND_VPN_SERVICE"` and
`android:stopWithTask="false"`.

### 4.2 The specialUse foreground service note

Android 14 (API 34) requires every foreground service to declare a type.
The tunnel service declares:

```xml
android:foregroundServiceType="specialUse"
...
<property
	android:name="android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE"
	android:value="vpn" />
```

and `PhantrixTunnelService.startForegroundCompat()` calls
`startForeground(NOTIFICATION_ID, notification,
FOREGROUND_SERVICE_TYPE_SPECIAL_USE)` on SDK 34+.

`specialUse` is used deliberately and only after review: the service *is*
a system VPN, the `BIND_VPN_SERVICE` permission already gates who can
bind it, and the notification is low-importance with no vibration and no
badge. Do not "simplify" this by removing the type or the property —
Play Store review expects the property, and Android 14+ kills services
without a type.

### 4.2a Regenerate the plugin registrant before release builds

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

### 4.2b Dependency verification

`android/gradle/verification-metadata.xml` pins `sha256` values for every Gradle
artifact. A stale pin fails the build with `Dependency verification failed`.
If you bump a dependency, regenerate the pins (`gradlew --write-verification-metadata sha256`)
and review the diff; do not disable the check. Verification stays fully
enabled — no `trusted-artifacts` escape hatch is added.

### 4.3 Android signing for release

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
rules in `android/app/proguard-rules.pro` for everything the engine and the
WireGuard bridge look up by name. Keep the R8 mapping file from every release
— without it a crash report from a shipped build is unreadable:

```
build/app/outputs/mapping/release/mapping.txt
```

### 4.4 What the Android build does and does not give you

`flutter build apk --release` succeeds and produces a **minified, installable**
artifact. Confirm the `VpnService` really is in the merged manifest before
trusting it:

```powershell
$aapt = "$env:LOCALAPPDATA\Android\Sdk\build-tools\36.0.0\aapt2.exe"
& $aapt dump badging build\app\outputs\flutter-apk\app-arm64-v8a-release.apk |
  Select-String "uses-permission"
```

Expect exactly these permissions, with no `maxSdkVersion` cap on
`BIND_VPN_SERVICE` (capping it would leave the app without the permission on
newer Android releases and the system would refuse the bind):

```
android.permission.INTERNET
android.permission.BIND_VPN_SERVICE
android.permission.FOREGROUND_SERVICE
android.permission.FOREGROUND_SERVICE_SPECIAL_USE
android.permission.POST_NOTIFICATIONS
android.permission.RECEIVE_BOOT_COMPLETED
```

Anything else is a finding worth stopping for. There is no analytics SDK, no
location, no contacts, no storage, no `QUERY_ALL_PACKAGES`.

Confirm the tunnel service is bound to the permission and not exported:

```powershell
Select-String -Path build\app\intermediates\merged_manifest\**\AndroidManifest.xml `
  -Pattern 'PhantrixTunnelService' -Context 0,4
```

Expect `android:permission="android.permission.BIND_VPN_SERVICE"` and
`android:exported="false"`.

**What the build gives you:** a real WireGuard tunnel. `PhantrixTunnelService`
drives `com.wireguard.android.backend.GoBackend` from the official
`com.wireguard.android:tunnel` library, which performs all of the WireGuard
cryptography. No cryptography is implemented in this repository.

**What it does not give you:** a tunnel that has completed a handshake. That
needs a reachable WireGuard peer, and there is none in this environment. See
§4.5 and the README's platform table — "the engine is real" and "a connection
works" are separate claims and only the first one is currently true.

### 4.5 Proving a connection on a device

15 engine tests and 4 app tests run on an Android 14 x86_64 emulator and pass;
results are in `docs/evidence/`. They exercise the engine's own configuration
parsing, address assignment, routing and teardown.

They do **not** include a handshake, because there is no peer to hand-shake
with. To close that gap you need a WireGuard server you control. Supply its
configuration as an environment variable rather than committing it:

```powershell
$env:PHANTRIX_TEST_CONFIG = Get-Content .\peer.conf -Raw
flutter test integration_test -d <device-id>
```

Without it, report the connection as unverified. Do not describe byte counters
as handshake evidence: 148 bytes of handshake *initiation* queued toward a
black hole look exactly like a working tunnel in a counter-based UI.

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

The Windows tunnel backend drives two real engines and implements neither:

- **WireGuard** through the official **WireGuard for Windows** service
  (`wireguard.exe /installtunnelservice`), which must be installed
  separately (from wireguard.com). Without it the backend reports
  `backend.not_installed` and does nothing. Adding or removing a tunnel
  needs Administrator rights; the UAC prompt is raised by WireGuard's own
  service manifest.
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

- **Running a tunnel needs Administrator rights.** For WireGuard the prompt
  comes from WireGuard's own service manifest; for OpenVPN it comes from
  the helper's `runas` launch, which the user can also decline (reported as
  a failure, never retried silently). This code never elevates itself
  beyond that, never installs a driver outside the OpenVPN bundle flow, and
  never alters firewall rules.
- **There is no kill switch on Windows.** When the tunnel drops, traffic
  can leave over the normal network until the app reconnects. The app says
  so in Settings instead of claiming protection it does not have.

A WireGuard configuration file contains a private key, so it is written under the
per-user `%LOCALAPPDATA%` and deleted when the tunnel is removed. Every value
written to it has newlines stripped, because the file is consumed by a
process running as LocalSystem and a newline in a value would otherwise be
able to append an arbitrary directive to a system-privileged configuration.
An OpenVPN profile (which carries certificates and keys) is written to a
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

| Command | What it runs | Status recorded before this patch |
| --- | --- | --- |
| `cd packages/phantrix_core && dart test` | 173 domain tests across protocol parsing, validators, providers, scoring, state machine, redaction, fingerprints, full-tunnel repair, OpenVPN host validation | **173 pass** |
| `cd packages/phantrix_core && dart analyze` | Analyzer with strict modes | No issues found |
| `cd packages/phantrix_platform && dart analyze` | Plugin Dart code | No issues found |
| `cd packages/phantrix_platform && flutter test` | 20 bridge tests: state-machine wire round trip, `TunnelRequest` field presence and JSON encoding, the `PlatformEvent` handshake-versus-established distinction, and capability honesty | **20 pass** |
| `cd packages/phantrix_platform && dart analyze` | Plugin Dart code | No issues found |
| `flutter analyze` (root) | App + both packages | No issues found |
| `flutter test` (root) | 148 host tests: discovery merge/sort/dedup, HTTPS fetcher rules, server resolution and non-silent fallback, leak verification including captive-portal and stale-handshake attacks, connection state machine including a stale-callback race, localisation, privacy copy, widget semantics, whole-app smoke tests at 1x and 2x text scale | **148 pass** |
| `flutter test test/ui_screenshots_test.dart` | Renders the real widget tree to `docs/evidence/ui/` at four window sizes, both themes, and 1.6x text scale; fails on any overflow |
| `flutter test integration_test/ -d <device>` | **On-device** app tests: the real app, real platform channel, real OS | **4 pass** on Android 14 x86_64. Using the connect control with no reachable server reports honestly and never shows "Connected" |
| `gradlew :phantrix_platform:connectedAndroidTest` | **On-device** engine tests: loads the real `libwg-go.so` from the APK and drives the real `GoBackend` | **15 pass** on Android 14 x86_64. Evidence in `docs/evidence/` |
| `flutter build apk --release --split-per-abi` | R8-minified release APKs: armeabi-v7a 18.1 MB, arm64-v8a 20.8 MB, x86_64 22.4 MB. The Kotlin tunnel and the official WireGuard engine are compiled, not fetched. See 4.4 |
| `flutter build web --release` | Web build | **Succeeds** |
| `flutter build windows --release` | Windows release bundle (27.8 MB): `phantrix.exe` + `phantrix_platform_plugin.dll`. 21 artifact checks pass on the built binary |
| `flutter build ios` | iOS build | **Not attempted**: requires Xcode, a Mac and Apple signing. A complete `NEPacketTunnelProvider` and plugin bridge exist in `packages/phantrix_platform/apple/`; see the manual steps in its README |
| `flutter build macos` | macOS build | **Not attempted**: requires Xcode. The extension and plugin source exist in `packages/phantrix_platform/apple/`; signing and provisioning remain |
| `flutter build linux` | Linux build | **CI only** — no Linux toolchain here. `.github/workflows/linux.yml` compiles the plugin and app, and asserts the plugin registers and exports its entry point |
| `powershell -File tools/check_windows_build.ps1` | Built-artifact invariants: no shell, no command chaining, WireGuard service arguments present, no embedded private key |
| `powershell -File tools/windows_check.ps1` | Windows host readiness | Reports whether WireGuard is installed and whether the session is elevated. **Makes no system changes** — it never installs, starts or reconfigures anything |

### Continuous integration

Four workflows, each proving something the others cannot.

| Workflow | Runner | What it establishes |
| --- | --- | --- |
| `verify.yml` | Ubuntu 24.04 | `flutter analyze --fatal-infos`, formatting, and every test in all three packages. Uploads the rendered UI |
| `android.yml` | Ubuntu 24.04 | The Kotlin backend and the real WireGuard engine compile; JVM tests pass; a minified App Bundle and per-ABI APKs are produced |
| `linux.yml` | Ubuntu 24.04 | `phantrix_plugin.cc` compiles and links; the registrant calls the entry point and `nm -D` shows the `.so` exports it |
| `windows.yml` | Windows 2022 | The C++ backend compiles and links, and 21 checks pass **on the built binary** |

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
| `wireguard.exe`, `/installtunnelservice`, `/uninstalltunnelservice` present | the CLI contract silently changing, turning connect into a confusing runtime failure |
| no `PrivateKey=` in the binary | a shipped key, which would be a key for everybody who downloads the app |
| every bridge method name present | a rename breaking the plugin at run time rather than at build time |

**No workflow runs a tunnel.** None has a reachable WireGuard peer, so a green
run says nothing about whether traffic routes, and none of them claims
otherwise. Linux needs `CAP_NET_ADMIN`, Windows needs the WireGuard service and
an administrator token, and Android needs a device — none of which a CI job
should have.

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
| **On-device engine** | Android 14 emulator | `gradlew :phantrix_platform:connectedAndroidTest` | The native `libwg-go.so` loads and executes, configurations reach the official engine, the interface comes up, unreachable peers report no handshake | That a real peer answers |
| **On-device app** | Android 14 emulator | `flutter test integration_test/ -d <id>` | The real app starts, the first-run flow works, every screen lays out, and Connect never claims a false success | That a tunnel carries traffic |

Only the last two touch the operating system. Neither can prove traffic
routing, because that needs a reachable WireGuard peer, which this environment
does not have. A test that asserted a successful handshake without a peer
would be asserting something nobody checked.
