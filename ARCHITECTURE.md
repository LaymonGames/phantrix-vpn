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
	lib/storage/                 # AppStore: the app's own key/value persistence
	lib/settings/ lib/vpn/       # settings holder, connection controller, resolver
	lib/theme/ lib/l10n/         # colour/motion tokens + English/Arabic strings
	test/                         # 251 tests, incl. the rendered-UI suite
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
		test/                  # 197 core tests
	phantrix_platform/           # Flutter plugin: Dart bridge + Android/Linux/Windows/Apple native
		lib/phantrix_platform.dart
		android/src/main/kotlin/dev/phantrix/phantrix_platform/
			PhantrixPlugin.kt          # MethodChannel handler
			AndroidCapabilities.kt     # per-API-level capability facts
			VpnSettings.kt             # system lockdown reading, VPN settings screen
			EventChannelListener.kt    # the tunnel-state subscription Dart opens
		windows/phantrix_windows_plugin.cpp   # official OpenVPN binaries + elevated helper
		linux/phantrix_plugin.cc             # kernel WireGuard via wg-quick (pkexec)
		apple/                                # iOS + macOS: NEPacketTunnelProvider
			Sources/{Shared,Extension,App}/
			Entitlements/
			README.md                  # the Xcode wiring steps and what is unverified
	.github/workflows/linux.yml     # the only place the Linux plugin is compiled
	integration_test/               # ON-DEVICE app tests
	test/                           # 22 host tests
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
	Native (windows/phantrix_windows_plugin.cpp)
		   the channel handler, capability probing, the elevated OpenVPN helper
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
	"Handshake complete, verifying…". The Windows helper's event contract
	agrees: everything the OS reports as "up" is `established`, never
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

The `ConnectionController` in `lib/vpn/connection_controller.dart` runs
`LeakCheck` on `PlatformTunnelState.handshaked`; `established` alone is not
enough to promote the connection. It requires a recent,
non-future engine handshake and a changed public address in the same IP family
as the pre-connection baseline. The default HTTPS probes use IPv4 and fresh
clients so an old pooled connection cannot supply pre-tunnel evidence.
An unavailable baseline, failed probe, or unchanged address fails verification
and requests teardown rather than showing "connected". A refused teardown
remains an error, not a claimed disconnection. This gate measures the probed
IPv4 route; it does not verify DNS, IPv6, every application, or a kill switch.

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
| `stopTunnel` | none | void on confirmed stop; errors must not be treated as a disconnection |
| `openVpnSettings` | none | void; opens the OS VPN settings |
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
A missing native plugin produces
`platform.missing`: "This platform has no Phantrix tunnel implementation."

### 6.1a Persistence

One layer, deliberately separated from both the core package and the UI:

```
lib/storage/app_store.dart              AppStore interface
  ├─ MemoryAppStore                    tests, and the web
  └─ FileAppStore                      one JSON file, written atomically
        ▲
        │ FileAppStore.inDirectory(dir, fileName)
lib/settings/settings_controller.dart  what the app remembers between runs
lib/vpn/connection_controller.dart     re-validates, then starts the tunnel
```

The settings store holds preferences, favourites, and the last selected relay.
Separate files cache directory metadata and public VPN Gate profiles. The
profile cache can contain the feed's shared client private keys; base64 is not
encryption. Windows also stages a restricted per-session profile on disk and
retains bounded raw OpenVPN log archives. See
[SECURITY.md §4.0](SECURITY.md#40-at-rest-what-the-store-holds-and-what-it-does-not)
and [PRIVACY.md](PRIVACY.md) for retention and protection limits.

### 6.2 `startTunnel` argument shape

```
{
	configJson:   string   # JSON of the *validated* configuration:
	                      #   {"openvpn": {proto, dev, cipher?, auth?, remotes[...],
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

The receiving backend validates every field on arrival and rejects malformed
input with a *reason*, never a default: missing IPv6 policy fails (it never
silently means "allow"), two protocols at once fails, both allow- and
disallow-app lists fail, an empty private key or peerless config fails. Error
messages never include the payload, because the payload contains key material.
The Windows plugin is the only backend that receives this today; the Android
side answers a start request with the reason it cannot serve one.

### 6.3 Event payload shape (native → Dart)

```
{
	state:        'idle' | 'preparing' | 'connecting' | 'established'
	              | 'reconnecting' | 'disconnecting' | 'failed' | 'revoked'
	message?:     string        # short, non-secret
	errorCode?:   string        # e.g. 'tunnel.not_up'
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

The engine's capabilities type now has a single home:
`PlatformCapabilities` in
`phantrix_platform/lib/phantrix_platform.dart` is the wire DTO the UI
reads, and the duplicate that once lived in
`phantrix_core/src/vpn/vpn_engine.dart` has been removed. Importing both
packages no longer produces an ambiguous name, and `flutter analyze` is
clean at the root.

---

## 7. What is real, and what is scaffolding (honest inventory)

**Real and tested (`phantrix_core`, 197 tests):** WireGuard and OpenVPN
parsers, serializers and validators; the three providers; discovery,
caching and merging; scoring and selection; the state machine; settings;
diagnostics; the logger, the redactor and the secret fingerprint.

**Real and tested on a device (`phantrix_platform` Android, recorded before the
app became OpenVPN-only):** the plugin and channel plumbing, the capability
reporter, and 4 on-device app tests on a real Android 14 emulator. The
`VpnService` that drove the official WireGuard backend, its config mapper, its
routing policy and its request parser have since been removed: Android has no
engine in this build, so the app declines every relay there with an
explanation.

**Real and compiling (`phantrix_platform` Windows):** the C++ backend
builds (`phantrix.exe` + `phantrix_platform_plugin.dll`) and drives the
official OpenVPN 2.6 community binaries through the elevated helper. The
engine's presence is probed from disk: the `openVpn` capability is answered
from what is installed, so a build without the bundle declines an OpenVPN
server with an explanation instead of attempting a tunnel that cannot start.
It has connected live; see `docs/OPENVPN_BACKEND_VERIFICATION.md` §4 addenda.

**A system VPN cannot be sandboxed, and this one does not claim to be.** Every
tunnel on every platform has to create a network interface and change the
machine's routing table, and no unprivileged process may do either. What this
project does instead is
keep the elevation as far from the app as it can: `phantrix.exe` never runs
elevated, one small helper is launched per tunnel under a
`requireAdministrator` manifest, it holds the token only for the life of that
tunnel, and the two sides talk over a named pipe with an explicit
Medium-integrity DACL. That is the boundary that exists. "Sandboxed" is not
available for this class of program, and the app says so rather than implying
otherwise.

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

**Real and tested (`lib/`, 269 tests):** the Flutter UI. Theme tokens,
English and Arabic strings with RTL, a responsive three-tab shell — **Home,
Servers, Settings** as a sidebar on desktop and a bottom bar on mobile. The
sidebar's footer carries the live connection state, so the tunnel's status is
readable from every screen rather than only the connection screen. Diagnostics,
privacy and licences are opened *over*
those tabs as secondary screens that highlight their parent tab and offer a back
arrow — the connection screen, the server browser, the privacy diagnostics page,
the privacy explanation and settings. On top of
that, `lib/net/app_http_fetcher.dart` is the single outbound HTTPS path in
the app, `lib/discovery/` runs the providers and publishes a merged
`DirectorySnapshot`, and `lib/vpn/connection_resolver.dart` turns "connect me
to Japan" into a specific server plus its validated configuration. The
country list is derived from real servers; there is no fallback list of
invented countries. `flutter analyze` is clean at the root and
`flutter test` passes 250 tests, including whole-app smoke tests at 1x and 2x
text scale.

**The Dart plugin surface declares `android`, `linux` and `windows`, each
with native code behind it.** `macos` and `ios` are intentionally absent
from that list: the source exists in `apple/` but is not wired into
Flutter's plugin build, which needs Xcode. Declaring a platform with no
compiled source behind it produces either a build failure or a stub
answering "not supported" — a placeholder presented as a backend — so the
Dart layer reports Apple platforms as unsupported instead, and the
capabilities reporter says so explicitly.

**Not verified anywhere: leak behaviour, DNS and IPv6.** The Windows OpenVPN
tunnel has been observed live (`docs/evidence/openvpn/`): traffic flowed for
minutes and the exit address changed. What no platform has verified is what
happens to DNS and to IPv6 while the tunnel is up. Every platform's `connected`
requires three evidences, so an unverified tunnel fails closed rather than
reporting protection the user does not have. This is the single largest
remaining gap and it is called out in every document rather than blurred.

---

## 8. Where crypto lives

The project rule, stated in the code and repeated in SECURITY.md: **crypto
happens in vetted native or established libraries, and is never
hand-rolled.**

- **Android, today: no crypto at all in Dart.** There is no tunnel engine on
	Android in this build, so no key material reaches the platform and nothing
	is written to disk. If an engine is added, the wrapping key for any
	persistent (reboot-restore) tunnel must come from the AndroidKeyStore as a
	non-exportable AES-256-GCM key, using `javax.crypto` only — no third-party
	crypto library and no homemade key derivation. That work is not in this
	build; see the README.
- **Android, log safety:** exceptions raised while handling a platform reply
	are logged by class name only. `org.json` puts the offending value in its
	message, and that value is payload the app does not control, so logging
	the exception object would put it in logcat.
- **Manifest signatures:** `SignatureVerifier` in
	`manifest_provider.dart` uses `package:cryptography`'s Ed25519 — which
	is backed by a vetted native library where one exists — with explicit
	64-byte signature and 32-byte key length checks and a "return false,
	never throw" contract.
- **Protocol cryptography:** deliberately *not implemented here*. The
	Noise_IK handshake, ChaCha20-Poly1305 and the OpenVPN TLS stack live in
	the upstream engines (the Windows build drives the official OpenVPN 2
	binaries; the Linux backend drives the kernel's own implementation
	through `wg-quick`). The only "crypto-looking" code in Dart is
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
verification gate. The mapper has no Android twin any more — that one was
removed with the Android WireGuard backend — and it
enforces the same two invariants natively: `0.0.0.0/0` is added
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
