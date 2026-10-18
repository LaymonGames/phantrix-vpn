# Third-party licences

This inventory covers the dependencies declared in the project's build files
and the components bundled in release builds. If a dependency or binary
changes, update this document and regenerate the in-app inventory in the same
commit (`dart run tools/generate_third_party_notices.dart`).

## 1. Dart / Flutter dependencies

### `packages/phantrix_core/pubspec.yaml`

| Package | Declared | Locked | Licence | Used for |
| --- | --- | --- | --- | --- |
| `http` | `^1.2.2` | 1.6.0 | BSD-3-Clause | HTTP transport behind the `HttpFetcher` abstraction (providers fetch server lists with it) |
| `collection` | `^1.19.1` | 1.19.1 | BSD-3-Clause | List/map utilities used throughout the domain layer |
| `cryptography` | `^2.9.0` | 2.9.0 | **Apache-2.0** | Ed25519 verification of signed server manifests (`SignatureVerifier`); backed by a vetted native library where one exists |
| `meta` | `^1.16.0` | 1.19.0 | BSD-3-Clause | Annotations (`@visibleForTesting`-style metadata, `sealed` support helpers) |
| `test` (dev) | `^1.25.0` | 1.33.0 | BSD-3-Clause | The domain test suite |
| `lints` (dev) | `^5.0.0` | 5.1.1 | BSD-3-Clause | Lint rule set (`lints/recommended.yaml`) |

### `packages/phantrix_platform/pubspec.yaml`

| Package | Declared | Licence | Used for |
| --- | --- | --- | --- |
| `flutter` (SDK) | `sdk: flutter` | BSD-3-Clause | MethodChannel / EventChannel / PlatformException (`package:flutter/services.dart`) |
| `phantrix_core` | `path: ../phantrix_core` | **GPL-3.0-only for independently authored Phantrix code** | Types shared across the bridge (`AppError`, `VpnConfiguration`); see the scope caveat in `COPYRIGHT` |
| `flutter_test` (dev) | `sdk: flutter` | BSD-3-Clause | Test scaffolding for the plugin package |
| `lints` (dev) | `^5.0.0` | BSD-3-Clause | Lint rule set |

### Root `pubspec.yaml` (the app)

| Package | Declared | Licence | Used for |
| --- | --- | --- | --- |
| `flutter` (SDK) | `sdk: flutter` | BSD-3-Clause | The Flutter framework |
| `flutter_localizations` (SDK) | `sdk: flutter` | BSD-3-Clause | Localised framework strings for the English and Arabic UI |
| `http` | `^1.2.2` | BSD-3-Clause | HTTP client used by the app's single fetch path (`lib/net/app_http_fetcher.dart`) |
| `cupertino_icons` | `^1.0.8` | MIT | Icon font (Flutter template) |
| `url_launcher` | `^6.3.1` | BSD-3-Clause | Opens the Laymon Games portfolio link (Settings → About) in the system browser; its per-platform implementations (`url_launcher_android`, `_ios`, `_linux`, `_macos`, `_web`, `_windows`) are BSD-3-Clause too and are listed in the generated inventory |
| `flutter_test` (dev) | `sdk: flutter` | BSD-3-Clause | Widget-test scaffolding |
| `integration_test` (dev) | `sdk: flutter` | BSD-3-Clause | On-device tests; not shipped in releases |
| `flutter_lints` (dev) | `^6.0.0` | BSD-3-Clause | App lint set (`flutter_lints/flutter.yaml`) |

### Notable transitive Dart dependencies

The lockfiles include BSD-3-Clause packages such as `crypto` (via
`cryptography`), `ffi`, `typed_data`, `http_parser`, `path`, `async`, `meta`,
`collection`, `web`, `vm_service`, and packages used by `test`, plus
Apache-2.0 and MIT packages. The generated inventory lists each resolved
package with its detected licence and the full text when available. Flutter
and Dart SDK entries point to the SDK's aggregate licence-notice file, which
contains notices for components under multiple licences; it must not be
mistaken for one licence grant.

## 2. Android / Kotlin dependencies

From `packages/phantrix_platform/android/build.gradle.kts`:

### The tunnel engine

**There is none.** The Android plugin declares no dependencies at all: the
`com.wireguard.android:tunnel` library (Apache-2.0, the official WireGuard
Android engine) was removed on 16 October 2026, together with the `VpnService`,
the configuration mapper and the request parser that drove it, when the app
became OpenVPN-only. Android therefore cannot start a tunnel in this build, and
the app declines every relay there with an explanation. The one OpenVPN engine
available for Android, ics-openvpn, cannot be shipped either — see §6 and
`docs/LICENSING_AUDIT.md`.

`android/gradle/verification-metadata.xml` still pins SHA-256 checksums for
every Gradle artifact in the build (1169 artifacts today), so a substituted
artifact fails the build loudly rather than being linked quietly.

### Apple WireGuard source snapshot (not an enabled target)

`packages/phantrix_platform/pubspec.yaml` currently declares **Android, Linux
and Windows only**. The repository also contains an Apple source snapshot under
`packages/phantrix_platform/apple/`, with upstream-derived WireGuardKit glue and
MIT SPDX headers. Its provenance and MIT text are recorded in
`packages/phantrix_platform/apple/LICENSE-WireGuardApple`. However, there is no
iOS/macOS plugin declaration or build target in this checkout, so these files
must be treated as source-only—not as a shipped or release-ready Apple VPN
implementation. Preserve their upstream notices if developing an Apple port,
and verify the source revision/build setup before enabling those targets. No
separate OpenVPN iOS/macOS engine is enabled here.

### Supporting dependencies

The plugin module declares no dependencies of its own. The app module declares
only Flutter's build tooling:

| Dependency | Version | Licence | Used for |
| --- | --- | --- | --- |
| `com.android.application` | 9.1.0 (`android/settings.gradle.kts`) | Apache-2.0 | Android Gradle Plugin for the app |
| `org.jetbrains.kotlin.android` | 2.4.0 | Apache-2.0 | Kotlin compilation for the app |
| `dev.flutter.flutter-plugin-loader` | 1.0.0 | BSD-3-Clause | Flutter's Gradle plugin loader |
| Gradle (wrapper) | 9.3.1 | Apache-2.0 | Build tool, downloaded by `gradle/wrapper/gradle-wrapper.properties` |
| Android SDK Platform 35 | — | Android Software Development Kit License | `compileSdk = 35` in the plugin module (the app module uses Flutter's default compile and target SDK) |

There is no Fuchsia target in this repository. The plugin manifest declares
`android`, `linux` and `windows`; it does not declare `ios` or `macos`, despite
the Apple source snapshot described above.

## 3. The WireGuard protocol — licensing statement

- **"WireGuard" and the WireGuard logo are registered trademarks of Jason
	A. Donenfeld.** This project uses the name descriptively, as a
	compatible client may; no trademark licence is claimed or needed for
	describing protocol compatibility.
- The **WireGuard protocol design and its reference implementations**
	(`wireguard-linux`, the kernel module; `wireguard-go`, the userspace
	implementation) are **Copyright © Jason A. Donenfeld and contributors**,
	distributed under the **GNU General Public License v2** (the kernel
	component) and MIT (the `wireguard-go` userspace component). The
	protocol specification ("WireGuard: Next Generation Kernel Network
	Tunnel") is a published paper under the author's copyright.
- **This build does not ship or run any WireGuard engine.** The Windows app
	runs OpenVPN (§4) and nothing else, and the Android plugin has no engine
	at all. The WireGuard parser, validator and serializer in `phantrix_core`
	are pure-Dart code written for this project under its own GPL-3.0-only
	licence; no third-party WireGuard code is linked into the app.
- The **Linux backend source** (`packages/phantrix_platform/linux/`) drives
	the kernel's own WireGuard module through `wg-quick`. The kernel module is
	GPL-2.0, but it is part of the operating system and is not distributed
	with Phantrix; the backend invokes the user's separately installed
	`wireguard-tools`, which are GPL-2.0 and likewise not redistributed here.
	No kernel or `wireguard-tools` code is linked into or shipped with this
	GPL-3.0 application, so the licences do not have to combine.
- The **Apple source snapshot** keeps upstream's MIT headers (see §2). It is
	not a build target.
- The `wireguard-windows` package is deliberately **not** bundled or linked.
	It is GPL-2.0-only, which cannot be combined with this project's GPL-3.0.
	It is never a dependency of this project's build.

## 4. The OpenVPN protocol — licensing statement

- **"OpenVPN" is a trademark of OpenVPN Inc.**
- The **OpenVPN 2** implementation is open-source software, primarily
	under the **GNU GPL v2**. The protocol configuration format (`.ovpn`
	files) has no separate licence; implementations carry their own.
- This project's own code contains **no OpenVPN code**. It reads `.ovpn`
	configurations (parser in `packages/phantrix_core/lib/src/protocol/openvpn/`),
	enforces a security policy over them, and hands them to a platform VPN
	engine — on Windows, the official OpenVPN 2 binaries as a separate process.
	Android has no OpenVPN engine. The licensing consequences of
	each are in section 6.

## 5. Which component provides the VPN functionality, per platform

Honest inventory. "Implementation present" means real source exists; "verified"
separately records whether it was ever run. The Windows OpenVPN tunnel has been
observed working end to end (see `docs/evidence/openvpn/`); the WireGuard
sources in the tree have never completed a handshake in this environment,
because no reachable WireGuard peer exists here — and the app would refuse to
try, since it no longer offers the protocol.

| Platform | Implementation present? | Component providing it | Verified |
| --- | --- | --- | --- |
| Android | **No engine** | Nothing: the WireGuard engine, its `VpnService` and the mapper that drove it were removed on 16 October 2026, and no OpenVPN engine can be shipped | **Compiled and run on a real Android 14 x86_64 emulator, before the app became OpenVPN-only.** 4 app tests pass; the app now declines every relay with an explanation. |
| iOS | **No enabled plugin target** | Apple WireGuard source snapshot exists under `packages/phantrix_platform/apple/` (MIT), but no iOS target is declared by the plugin manifest | **Not a supported build target in this checkout.** |
| macOS | **No enabled plugin target** | Apple WireGuard source snapshot exists under `packages/phantrix_platform/apple/` (MIT), but no macOS target is declared by the plugin manifest | **Not a supported build target in this checkout.** |
| Linux | **Yes** | The **Linux kernel's own WireGuard module**, driven by official `wireguard-tools` (`wg-quick`) elevated through `pkexec` | **Compiled in CI**, and asserted to register and export its entry point. Never run against a live system. |
| Windows | **Yes** | The official **OpenVPN 2 community binaries**, run as a separate elevated helper process (`phantrix_ovpn_helper.exe`); wintun is the driver | **Connected live:** one tunnel observed for 6.5 minutes with a changed exit address (`docs/evidence/openvpn/`). |
| Web | **No, by design** | A browser cannot move system traffic; `PlatformCapabilities.web` says so and `startTunnel` fails explicitly | N/A |

### Linux and Windows use a maintained engine, not a reimplementation

The Linux backend contains **zero** WireGuard cryptography: it shells out to
`wg-quick`, and neither `wireguard-tools` nor the kernel module is bundled or
redistributed by Phantrix — they are installed separately by the user. The
Windows backend is the same story with OpenVPN: the official community
binaries run as a separate process and are fetched from the official source
by `tools/fetch_openvpn_bundle.ps1` rather than committed. This is deliberate:
the maintained implementations on those platforms are the engine, and
reimplementing a VPN protocol would be a large new attack surface for no gain.

Everything else in the project — protocol parsing and validation, server
providers, discovery, scoring, the state machine, settings, diagnostics
and the redacting logger — is Phantrix's own GPL-3.0 code in
`packages/phantrix_core`.

## 6. OpenVPN (Windows only)

Phantrix's original code is GPL-3.0-only. Android ships **no OpenVPN engine**:
the only available one, ics-openvpn (OpenVPN for Android), is distributed under
GPL version 2 (its own licence file says "GPL license version 2", F-Droid lists
GPL-2.0-only), and GPL-2.0-only code cannot be combined with GPL-3.0 code in one
distributed work. It was removed rather than relicensed around; the reasoning
and the evidence are recorded in `docs/LICENSING_AUDIT.md`.

### Windows: OpenVPN 2 community binaries and wintun

- The Windows backend runs the **official OpenVPN 2 community binaries**
  (`openvpn.exe` plus its runtime DLLs) as a **separate, elevated helper
  process** — launched through `ShellExecuteExW("runas")` so the app itself
  is never elevated. OpenVPN 2 is **GPL-2.0**; a separate process is neither
  linked with nor derived from this GPL-3.0 application, which is the only
  reason the two may sit in one installer.
- The download is pinned by URL and SHA-256 in
  `tools/fetch_openvpn_bundle.ps1`, which verifies the hash before
  extracting anything.
- The tunnel device is **wintun** (`wintun.dll`, WireGuard LLC), whose
  "Prebuilt Binaries License" text is reproduced in
  `tools/attribution/wintun-prebuilt-license.txt`. The licence's redistribution
  exception is conditional: the DLL must be shipped alongside software that
  uses it exclusively through the permitted `wintun.h` API. OpenVPN is the
  runtime API consumer, not Phantrix itself; keep the DLL unchanged and paired
  with OpenVPN, and validate that the exact bundle meets this condition.
- This backend is not hypothetical: it has been run live on Windows. The
  observed connection, exit-IP change and held tunnel are recorded in
  `docs/evidence/openvpn/WINDOWS_VERIFICATION_2026-10-11.md`, with the raw
  capture beside it.

### Glue code adapted from openvpn_dart

Parts of the platform glue (config hand-off, status parsing, helper process
management) are adapted from the MIT-licensed `openvpn_dart` project,
**Copyright (c) 2023 BlockDev AG** — the full MIT text is reproduced in
`tools/attribution/openvpn-dart-license.txt` and the entry is marked
`adaptedUpstream` in the in-app inventory. The Android Kotlin glue that was
also adapted from it went away with the Android OpenVPN engine, so this
now applies to the Windows backend only.

**Open item:** the Windows C++ sources under
`packages/phantrix_platform/windows/` carry no per-file attribution comment
naming `openvpn_dart`; the attribution exists only in `tools/attribution/`, the
generator and the in-app inventory. Before a release, confirm which files the
notice covers and consider adding a header comment to them.

## 7. The in-app notices inventory is generated, not written by hand

`tools/generate_third_party_notices.dart` derives every line the app shows
from files that exist in this repository or in a local toolchain cache:

- `pubspec.lock` of the app and both packages, for Dart dependencies and
  their resolved versions;
- the `LICENSE` file of each package in the pub cache, for the licence
  **text** (absent cache ⇒ an explicit "not found", never a guess);
- the Gradle dependency blocks, with licences read from vendored or cached
  Maven POMs, for Android artefacts;
- the Windows bundle's own licence files, for the OpenVPN and wintun
  binaries;
- `tools/attribution/`, for the components checked in section 6.

It emits `lib/notices/generated_third_party_notices.dart` (consumed by the
Licenses & credits screen) and this document's facts can be re-checked
against it. The output is deterministic: re-running over unchanged inputs
produces a byte-identical file. Re-run it after any dependency change, as
described in README.md.

An entry whose licence cannot be read reports `unknown` and names the file
it looked for, and the UI says so. There is deliberately no fallback that
guesses a licence from a package name.
