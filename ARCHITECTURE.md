# Architecture

## 1. Package layout

```
phantrix/                          # root Flutter app
	lib/main.dart                # entry point; awaits AppScope.bootstrap()
	lib/phantrix_app.dart        # AppScope wiring + first-run flow + navigation
	lib/ui/                      # shell, screens, components (navigation, connection_orb,
	                                #   surfaces, rows, brand, status_style)
	lib/discovery/               # DiscoveryController + the async→UI bridge
	lib/net/                     # the single outbound HTTPS path
	lib/config/                  # ConfigurationRepository — imported WireGuard configs
	lib/storage/                 # AppStore: the app's own key/value persistence
	lib/settings/ lib/vpn/       # settings holder, connection controller, resolver
	lib/theme/ lib/l10n/         # colour/motion tokens + English/Arabic strings
	test/                         # 119 tests, incl. the rendered-UI suite
	android/ linux/ macos/ windows/ web/   # Flutter platform scaffolds
tools/                          # CI helpers + read-only diagnostics
packages/
	phantrix_core/               # pure Dart domain — the heart of the project
		lib/src/
			core/                # Result, AppError, SelectionReason
			model/               # VpnServer, TrustLevel, ServerStatus, LoggingPolicy
			protocol/            # WireGuard + OpenVPN parse / validate / serialise
			providers/           # vpngate, manifest (signed), imported
			discovery/           # ServerDirectory, cache, merger
			scoring/             # ServerScorer, ServerSelector
			vpn/                 # VpnStateMachine, VpnEngine contract, ConnectionSession
			settings/            # AppSettings (immutable)
			diagnostics/         # privacy check model
			logging/             # Logger + Redactor
		test/                  # 171 core tests
	phantrix_platform/           # Flutter plugin: Dart bridge + Android/Linux/Windows/Apple native
		lib/phantrix_platform.dart
		android/src/main/kotlin/dev/phantrix/phantrix_platform/
			PhantrixPlugin.kt          # MethodChannel handler
			PhantrixTunnelService.kt   # VpnService driving the official GoBackend
			WgConfigMapper.kt          # validated Dart config → com.wireguard.config.Config
			TunnelRequestParser.kt     # strict JSON decode of the tunnel request
			RoutingPolicy.kt           # routes, DNS, IPv6 policy
			AndroidCapabilities.kt     # per-API-level capability facts
			VpnPermissions.kt          # consent flow, settings screen
			EventChannelListener.kt   # service → Dart state stream
		android/src/androidTest/…     # ON-DEVICE tests: loads the real libwg-go.so
		windows/phantrix_windows_plugin.cpp   # official wireguard.exe service
		linux/phantrix_plugin.cc             # kernel WireGuard via wg-quick (pkexec)
		apple/                                # iOS + macOS: NEPacketTunnelProvider
			Sources/{Shared,Extension,App}/
			Entitlements/
			README.md                  # the Xcode wiring steps and what is unverified
	.github/workflows/linux.yml     # the only place the Linux plugin is compiled
	integration_test/               # ON-DEVICE app tests
	test/                           # 105 host tests
```

Two packages, one rule: **the domain never reaches for the platform.**

---

## 2. The layering

```
	UI (lib/, widgets landing now)          — Flutter widgets, no protocol logic
		│  reads ConnectionView snapshots; never calls the platform itself
	Domain (packages/phantrix_core)            — pure Dart, zero Flutter, zero platform
		│  provides validated VpnConfiguration, servers, state transitions
	Platform bridge (packages/phantrix_platform Dart side)
		│  MethodChannel + EventChannel, DTOs only
	Native (android/src/main/kotlin/...)
		   VpnService, keystore, routing policy, event publishing
```

Dependencies point one way only. `phantrix_platform` depends on
`phantrix_core`; `phantrix_core` depends on nothing of ours. The UI in `lib/` is the only layer allowed to hold Flutter
widgets, and the connection half of it is deliberately narrow:
`lib/vpn/connection_controller.dart` holds `SettingsController`, the
`LeakCheck`, and the only code allowed to move the state machine, and it
doubles as the seam that turns domain objects into platform DTOs.

---

## 3. Why the core is pure Dart

`phantrix_core` has `dependencies: http, collection, cryptography, meta`
and `dev_dependencies: test, lints`. No Flutter SDK. That is a design
decision, not an accident:

- **Testability without a device.** All 150 core tests run on the Dart VM in
	under a second. A config validator that needs an emulator does not get
	tested 117 times.
- **Determinism.** `VpnStateMachine.reduce` is a pure function from
	(state, event) to transition; `ServerScorer.scoreDetailed` is a pure
	function from (server, context) to score. The same input always
	produces the same output, which is what makes the rules provable.
- **Portability.** The same domain compiles for Android, iOS, desktop and
	web. When the iOS tunnel lands, it must conform to the *same*
	contracts, not a dialect of them.
- **Reviewability.** Security policy lives in one place that can be read
	on its own: `WgValidator`, `OvpnValidator`, `Redactor`.

The cost is that the core cannot talk to an OS at all. Everything the OS
must do is expressed as an *effect* (`VpnEffect.startTunnel`,
`VpnEffect.requestPermission`, `VpnEffect.awaitNetwork`, …) or an *event*
(`VpnEvent.tunnelUp`, `VpnEvent.tunnelVerified`, …). Somebody else
performs the effects; the core only decides what they mean.

---

## 4. The provider abstraction

`ServerProvider` (`lib/src/providers/common/server_provider.dart`) is the
one interface every server source implements:

```dart
abstract class ServerProvider {
	String get id;                       // stable, e.g. 'vpngate'
	String get label;                    // shown in settings
	ProviderCapabilities get capabilities;
	bool get autoRefresh;
	String get trustDescription;         // shown next to every server from this source
	Future<RefreshOutcome> refresh();
	Future<ProviderConfig?> fetchConfig(String serverId);
	HttpFetcher get fetcher;             // injected, so tests supply a fake
}
```

The contract's teeth, all enforced in code:

- `refresh()` **never throws** — it returns `RefreshOutcome.failure(error)`.
	A dead provider must take down one list, not the app.
- `ProviderConfig` carries both `rawText` (diagnostics only) and
	`validated` (the only thing that may start a tunnel). The raw text is
	never used to connect.
- Providers must "never fabricate a status, latency or score". The VPN
	Gate provider parses and validates every row *before* offering it, so
	the advertised count is the usable count.
- Network access is behind `HttpFetcher`, a one-method abstraction with a
	documented `maxBodyBytes` cap, so TLS behaviour and size limits live in
	exactly one place and tests never touch the network.

`ServerDirectory` merges all providers into one immutable
`DirectorySnapshot`: de-duplicated, provenance kept, stale-vs-fresh vs
offline-using-cache distinguished (`DirectoryState`), and one failing
provider recorded in `providerErrors` instead of emptying the screen.

`ServerScorer` / `ServerSelector` then rank. The scorer is a weighted
*mean* (so 100 and 0 mean the same thing under any weight profile),
returns 0 with empty partials for an ineligible server rather than
dropping it (so the UI can explain *why* a server was not chosen), and
weights trust lowest of all — 0.3 — because "who runs this" must never
override "does this work". The selector's rule is *never silently
substitute*: a fallback ships with `Selection.fellBack` and a human
explanation.

---

## 5. The state machine

`VpnStateMachine` (`lib/src/vpn/vpn_state_machine.dart`) is the only
authority on what the app claims. Its single most important rule, from
the library doc comment and enforced twice:

> The state may only become `VpnState.connected` after the tunnel has
> actually been established *and* verified.

The enforcement:

1. **In `reduce`:** the only case that can produce
	`VpnTransition(VpnState.connected)` is `VpnEventType.tunnelVerified`.
	`tunnelUp` — the OS saying the interface exists — deliberately keeps
	the machine in `connecting`/`reconnecting` with the message
	"Handshake complete, verifying…". The Android service agrees: its KDocs
	state that everything the OS reports as "up" is `established`, never
	`connected`.
2. **In `allows`:** a second, independent guard used by hosts as a
	cross-check. `connected` is reachable only from `connecting` or
	`reconnecting`. If an engine ever reports a state the machine would
	not have produced, the host rejects and logs it.

The machine also refuses to be forced: `_protectedStates` means an idle
notification while the user is looking at a real terminal state
(`disconnected`, `connected`, `blocked`) is ignored, and a
`connectRequested` while connected is interpreted as "disconnect", not a
double-connect.

Cancelling belongs to the host, not the machine. `ConnectionController`
carries an *attempt generation* (`_attemptEpoch`) that is claimed when an
attempt starts and bumped when one is abandoned; every `await` inside
`connect` is followed by a check of the generation it began with, because a
cancelled attempt does not stop in mid-air — it wakes up later on whatever
platform call it was suspended in. `cancel()` is what the connect control
fires while an attempt is running and what a change of server fires before
the next one: it invalidates those continuations, completes any waiting
caller with `tunnel.cancelled` (deliberately **not** walkable, so an
automatic walk stops instead of dialling the next relay after the user said
stop), and tears the tunnel down. Nothing about it is reported as a failure
— no error, no retry card — and a launch that answers afterwards finds an
attempt that no longer exists, so it stops its own tunnel and says nothing.

The `ConnectionController` in `lib/vpn/connection_controller.dart` shows
the intended host: on `PlatformTunnelState.established` it runs
`LeakCheck` — a public-IP probe compared against the pre-connection
baseline — and only a *changed* IP produces `tunnelVerified`. An
unchanged IP means traffic never left through the tunnel, and the
controller fails the connection (`leak.unverified`) and tears it down
rather than showing "connected". Honest status: the probe itself is
still a stub (`LeakCheck.currentIp()` returns null, on the principle
that "could not measure" is not "no leak"), so until it is implemented
the controller cannot reach `connected` through it — which is the
correct failure direction.

Error codes are stable strings (`wg.handshake_timeout`, `permission.revoked`,
`server.unreachable`, `dns.failed`, `kill_switch.unsupported`, …),
mapped to human messages in one place
(`_messageFor` in `phantrix_platform.dart`), so the UI, the logs and the
tests all speak the same vocabulary across releases.

---

## 6. The platform bridge contract

Two channels, both named in `packages/phantrix_platform/lib/phantrix_platform.dart`
and mirrored by every native backend (`PhantrixPlugin.kt`,
`phantrix_windows_plugin.cpp`, `phantrix_plugin.cc`,
`apple/Sources/App/PhantrixPlugin.swift`):

| Channel | Name |
| --- | --- |
| MethodChannel | `dev.phantrix.phantrix/tunnel` |
| EventChannel | `dev.phantrix.phantrix/tunnelEvents` |

### 6.1 Methods (Dart → native)

| Method | Arguments | Result |
| --- | --- | --- |
| `capabilities` | none | capability map (6.3) |
| `requestPermission` | none | `bool`; false when refused. Never throws |
| `startTunnel` | request map (6.2) | void on acceptance only — **acceptance is not "tunnel up"** |
| `stopTunnel` | none | void; always cleans up, even mid-connect |
| `openVpnSettings` | none | void; opens the OS VPN settings |
| `reportVerification` | `{ipv4, ipv6, protocol}` | void; tells the platform the caller verified the tunnel |
| `appDataDirectory` | none | `String?`; the platform's private per-user directory, or null where none exists |

`appDataDirectory` returns a **path** rather than reading or writing a file
through the bridge, because the semantics of "write this file" are identical on
every platform and only the directory differs. Doing the I/O in Dart keeps one
atomic-write implementation rather than five. Each backend returns its own
platform's private location — `filesDir` on Android, `%LOCALAPPDATA%\Phantrix`
on Windows, `$XDG_CONFIG_HOME/phantrix` on Linux, Application Support on Apple
— and the web returns null, which `openDefaultStore` turns into an in-memory
store. **null is not an error**: an app that cannot persist still has to work.

`startTunnel` returning success means "the platform accepted the
request". The only way to know the tunnel exists is the event stream —
exactly the discipline the state machine depends on. Failures come back as
`PlatformException`s translated to `AppError` by group (`wg.*`/`ovpn.*` →
tunnel, `permission.*`/`dns.*` → permission, `server.*` → provider).
A missing native plugin — every platform except Android today — produces
`platform.missing`: "This platform has no Phantrix tunnel implementation."

### 6.1a Persistence and configuration import

Two layers, deliberately separated from both the core package and the UI:

```
lib/storage/app_store.dart              AppStore interface
  ├─ MemoryAppStore                    tests, and the web
  └─ FileAppStore                      one JSON file, written atomically
        ▲
        │ FileAppStore.inDirectory(dir, fileName)
lib/config/configuration_repository.dart
  └─ ConfigurationRepository           parse → validate → persist → list → connect
        ▲
        │ AppScope.connectToConfiguration()
lib/vpn/connection_controller.dart     re-validates, then starts the tunnel
```

`ConfigurationRepository` is the layer that made this application usable. The
only bundled feed publishes **OpenVPN**; every native backend drives
**WireGuard**; so before it existed there was no configuration a user could
supply and therefore nothing to connect to. It:

- parses and **validates before persisting** — an unchecked configuration is
  never written and never reaches a platform;
- derives its id from the *public* keys, so importing the same configuration
  twice updates the entry instead of creating a duplicate;
- re-validates on connect rather than trusting a cached verdict, because the
  validator may have been tightened since the configuration was imported, and a
  tunnel is the last thing to start from a cached "this was fine yesterday";
- is **not** part of the discovery layer. Imported configurations are not a
  directory of public relays to be scored against each other; they are entries
  the user chose, listed in import order and connected to directly.

Storing them is discussed, with what it does and does not protect, in
[SECURITY.md §4.0](SECURITY.md#40-at-rest-imported-configurations-are-stored-in-plain-text).

### 6.2 `startTunnel` argument shape

```
{
	configJson:   string   # JSON of the *validated* configuration:
	                      #   {"wireguard": {privateKey, addresses[], dns[], mtu,
	                      #                 peers[{publicKey, presharedKey?,
	                        endpoint, allowedIps[], persistentKeepalive?}]}}
	                      # or {"openvpn": {proto, dev, cipher?, auth?, remotes[...],
	                      #                 ca?, cert?, key?, tlsAuth?, authUserPass}}
	killSwitch:   'off' | 'automatic' | 'strict'
	dnsMode:      'vpn' | 'trusted' | 'custom'
	customDns:    string[]
	ipv6:         'prefer_tunnel' | 'block' | 'allow'
	mtu:          int?
	serverId:     string
	countryLabel: string
	allowedApps?: string[]      # at most one of allowed/disallowed
	disallowedApps?: string[]
	allowLan?:    bool
}
```

`TunnelRequestParser.parse` on the Android side validates every field on
arrival and rejects malformed input with a *reason*, never a default:
missing IPv6 policy fails (it never silently means "allow"), two
protocols at once fails, both allow- and disallow-app lists fail, an
empty private key or peerless config fails. Error messages never include
the payload, because the payload contains keys.

### 6.3 Event payload shape (native → Dart)

```
{
	state:        'idle' | 'preparing' | 'connecting' | 'established'
	              | 'reconnecting' | 'disconnecting' | 'failed' | 'revoked'
	message?:     string        # short, non-secret
	errorCode?:   string        # e.g. 'wg.handshake_timeout'
	networkChanged?: bool
	traffic: {
		rx: int, tx: int, rxRate?: int, txRate?: int,
		lastHandshake?: int(ms) | ISO string,
		ipv4?: string, ipv6?: string, protocol?: string
	}
	capabilities?: {             # sent on startup and after changes
		platform: string,        # e.g. 'android-35'
		killSwitch: bool, ipv6Block: bool, vpnDns: bool, perApp: bool,
		lanBypass: bool, alwaysOn: bool, tray: bool, bootStart: bool,
		limitations: {key: explanation}
	}
}
```

`PlatformTunnelState` mirrors — but is not — `VpnState`. `established`
is a fact about the OS; `connected` is a conclusion about the tunnel, and
only Dart is allowed to draw it. The EventChannel replays the last state
to a late subscriber (`EventChannelListener.onListen`) so a reattached UI
never shows a stale "disconnected" while a tunnel is up.

### 6.4 Capability reporting

`PlatformCapabilities` exists so the UI can refuse to offer a control the
platform will ignore. Unknown values default to *unsupported*: an
unreachable platform layer yields all-false capabilities plus a
`platform` limitation explaining why, and the web profile
(`PlatformCapabilities.web`) states plainly that a browser cannot protect
traffic outside itself. `AndroidCapabilities.of()` computes facts from
`Build.VERSION.SDK_INT`: kill switch from API 21, per-app tunnelling from
API 29 (Q), IPv6 blocking always, and pre-Q devices get a `perApp`
limitation string instead of a silent downgrade.

One known wart: the name `PlatformCapabilities` exists in **both**
packages — `phantrix_core/src/vpn/vpn_engine.dart` (the engine contract's
version, which also carries `killSwitchStrictness`) and
`phantrix_platform/lib/phantrix_platform.dart` (the wire version). The
bridge one is the DTO the UI should use, and the collision is one of the
current analyzer errors in `lib/vpn/connection_controller.dart`;
resolving it (an import prefix, or removing the unused duplicate from
core) is part of finishing the UI wiring, not something to paper over.

---

## 7. What is real, and what is scaffolding (honest inventory)

**Real and tested (`phantrix_core`, 171 tests):** WireGuard and OpenVPN
parsers, serializers and validators; the three providers; discovery,
caching and merging; scoring and selection; the state machine; settings;
diagnostics; the logger, the redactor and the secret fingerprint.

**Real and tested on a device (`phantrix_platform` Android):** the plugin
and channel plumbing; the `VpnService` subclass driving the official
`GoBackend`; the config mapper; the strict request parser; the capability
reporter. `flutter build apk --debug` succeeds, the merged manifest
contains both `VpnService`s, and `connectedAndroidTest` passes 15 tests on
a real Android 14 emulator — including loading `libwg-go.so` from the APK
and bringing an interface up. A **handshake** has never completed, because
no reachable peer exists in this environment.

**Real and compiling (`phantrix_platform` Windows):** the C++ backend
builds (`phantrix.exe` + `phantrix_platform_plugin.dll`) and drives the
official WireGuard for Windows service. Never exercised at runtime, because
WireGuard for Windows is not installed here and the session is not
Administrator.

**Real source, compiled by CI (`phantrix_platform` Linux):** the C++
backend is complete — capability probing, a fixed interface name,
0600-staged configuration, an `install -m 600` and a `wg-quick up`/`down`
lifecycle, and argument-vector privilege elevation. `.github/workflows/
linux.yml` compiles it and asserts it registers and exports its entry
point. It has never run against a live system; see
`docs/LINUX_RUNTIME_TESTING.md`.

**Real source, never compiled (`phantrix_platform` Apple):** `apple/`
holds a complete implementation for iOS and macOS — a real
`NEPacketTunnelProvider` using the official `WireGuardAdapter`, a
`NETunnelProviderManager` wrapper, the configuration mapper, the Flutter
bridge, entitlements and the extension Info.plist, with upstream
wireguard-apple sources vendored under their MIT licence. It has never
been compiled (no Xcode) or signed (no Apple Developer account). It is
ready for validation, not working.

**Real and tested (`lib/`, 105 tests):** the Flutter UI. Theme tokens,
English and Arabic strings with RTL, a responsive three-tab shell — **Home,
Servers, Settings** as a sidebar on desktop and a bottom bar on mobile. The
sidebar's footer carries the live connection state, so the tunnel's status is
readable from every screen rather than only the connection screen. Import/manage
configurations, diagnostics, privacy and licences are opened *over*
those tabs as secondary screens that highlight their parent tab and offer a back
arrow — the connection screen, the server browser, the privacy diagnostics page,
the privacy explanation and settings. On top of
that, `lib/net/app_http_fetcher.dart` is the single outbound HTTPS path in
the app, `lib/discovery/` runs the providers and publishes a merged
`DirectorySnapshot`, and `lib/vpn/connection_resolver.dart` turns "connect me
to Japan" into a specific server plus its validated configuration. The
country list is derived from real servers; there is no fallback list of
invented countries. `flutter analyze` is clean at the root and
`flutter test` passes 105 tests, including whole-app smoke tests at 1x and 2x
text scale.

**The Dart plugin surface declares `android`, `linux` and `windows`, each
with native code behind it.** `macos` and `ios` are intentionally absent
from that list: the source exists in `apple/` but is not wired into
Flutter's plugin build, which needs Xcode. Declaring a platform with no
compiled source behind it produces either a build failure or a stub
answering "not supported" — a placeholder presented as a backend — so the
Dart layer reports Apple platforms as unsupported instead, and the
capabilities reporter says so explicitly.

**Not verified anywhere: a completed handshake, and therefore DNS, IPv4
and IPv6 routing, and leak behaviour.** Every platform's `connected`
requires three evidences, so an unverified tunnel fails closed rather than
reporting protection the user does not have. This is the single largest
remaining gap and it is called out in every document rather than blurred.

---

## 8. Where crypto lives

The project rule, stated in the code and repeated in SECURITY.md: **crypto
happens in vetted native or established libraries, and is never
hand-rolled.**

- **Android, today: no crypto at all in Dart.** The tunnel configuration,
	including the private key, is handed to the native side in memory via
	`PendingRequest` and cleared as soon as the service has read it. Nothing
	is written to disk, so there is nothing to encrypt at rest. When
	persistent (reboot-restore) tunnels are added, the wrapping key must come
	from the AndroidKeyStore as a non-exportable AES-256-GCM key, using
	`javax.crypto` only — no third-party crypto library and no homemade key
	derivation. That work is not in this build; see the README.
- **Android, log safety:** exceptions raised while parsing or building the
	tunnel are logged by class name only. `org.json` puts the offending value
	in its message and that value is the configuration, so logging the
	exception object would put a private key in logcat.
- **Manifest signatures:** `SignatureVerifier` in
	`manifest_provider.dart` uses `package:cryptography`'s Ed25519 — which
	is backed by a vetted native library where one exists — with explicit
	64-byte signature and 32-byte key length checks and a "return false,
	never throw" contract.
- **Protocol cryptography:** deliberately *not implemented here*. The
	Noise_IK handshake, ChaCha20-Poly1305 and the OpenVPN TLS stack live in
	the upstream engines (`com.wireguard.android:tunnel`, Apache-2.0, is
	the intended Android engine). The only "crypto-looking" code in Dart is
	the FNV-1a digest in `Redactor.fingerprint` and `VpnConfiguration`, used
	solely to produce stable, non-reversible markers for log correlation —
	it protects nothing and is documented as such.
- **Keys in transit:** private keys are handed to the platform only as a
	validated configuration through the bridge, are never written to logs
	(see `Redactor`), and the tunnel request is staged in memory for the
	service to consume, never persisted.

---

## 9. The Apple tunnel shape

The Apple backend in `packages/phantrix_platform/apple/` is a
`NEPacketTunnelProvider` extension plus an app-side manager, joined
through the shared app-group container. This is the only shape Apple
permits, and the reason is worth stating plainly.

`NEPacketTunnelProvider` runs **out of process**, in its own sandbox,
launched by the OS. It cannot be started by the app and it cannot call
back into it. The configuration therefore travels one way only:

```
Dart → method channel → PhantrixPlugin
                        → NETunnelProviderManager (save, then activate)
                          → OS launches PhantrixPacketTunnelProvider
                            → read config from the shared keychain
                              → WireGuardAdapter → wireguard-go
```

The consequence is that the private key lives in the **shared app-group
keychain**, not in `providerConfiguration` — the latter is a plist in the
VPN preferences and is not encrypted. `PhantrixVPNManager.stop` deletes
that keychain item, so a key does not outlive the tunnel it belonged to.

### Why upstream sources are vendored

The SPM product `WireGuardKit` provides the engine types
(`TunnelConfiguration`, `InterfaceConfiguration`, `PeerConfiguration`,
`PrivateKey`, `PublicKey`, `IPAddressRange`, `DNSServer`, `Endpoint`,
`WireGuardAdapter`). It does **not** provide the application glue, which
lives in the app and extension targets in wireguard-apple's own
repository. Rather than reimplement that glue — and get the keychain
access-group model or the wg-quick serialisation subtly wrong — it is
vendored: `Keychain.swift`, `FileManager+Extension.swift`,
`ErrorNotifier.swift`, `Logger.swift`, `NotificationToken.swift`,
`String+ArrayConversion.swift`,
`NETunnelProviderProtocol+Extension.swift` and
`TunnelConfiguration+WgQuickConfig.swift`, under their original MIT
licence, recorded in `LICENSE-WireGuardApple`.

### What is Phantrix's own

The provider subclass, the manager (including loading the existing
manager via `loadAllFromPreferences` rather than creating a duplicate),
the configuration mapper with its full-tunnel and IPv6 guarantees, the
Flutter bridge, and the handshake-time polling that feeds the Dart
verification gate. The mapper is the Apple twin of `WgConfigMapper.kt`,
and it enforces the same two invariants natively: `0.0.0.0/0` is added
when a peer has no default route, and IPv6 routes are stripped when the
policy forbids carrying IPv6.

### Honest state

**Never compiled, never signed, never run.** Compilation needs Xcode; the
packet-tunnel entitlement, the app group, and the extension's signature
need an Apple Developer account. The wiring steps that remain are listed
in `packages/phantrix_platform/apple/README.md`, and the plugin pubspec
does not declare `ios` or `macos` until those are done — because
declaring a platform with no compiled source behind it is a placeholder
presented as a backend.

---

## 10. The Linux privilege boundary

Linux needs `CAP_NET_ADMIN` to create an interface, and a desktop
application does not have it. The backend elevates through `pkexec`,
which shows a visible system dialog. Three properties matter:

**Elevation is narrowly scoped.** Exactly one command is elevated at a
time — `install`, `wg-quick up`, `wg-quick down`, `rm` — and nothing else
runs as root. There is no daemon, no cached credential, and no
`sudo -S` with a password piped in.

**Arguments are an argument vector, not a shell string.**
`runElevated` builds `posix_spawnp` argv. No shell is involved, so no
character in any argument can mean "end of argument" or "new command". A
path or a value containing `;`, `$`, a quote or a newline is passed to the
program as literal characters. This replaced a `std::system`
implementation that built a command string, and the CI workflow fails if
`std::system` is reintroduced.

**Injection into the configuration file is still defended.**
`renderConfig` strips newlines from every value before writing. That
matters independently of the shell: the file is read by `wg-quick` **as
root**, and a value with a newline in it could append a `PostUp`
directive and gain root command execution through wg-quick itself rather
than through a shell.

Exit codes distinguish four failure modes, because they need different
responses from the user: `126`/`127` report `permission.denied` (retry
and approve the prompt), anything else reports `tunnel.failed`. A
failure after `wg-quick up` runs `wg-quick down` first, so a
half-raised interface is never left in place.
