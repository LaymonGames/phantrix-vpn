# The Apple backend

A real `NEPacketTunnelProvider` and `NETunnelProviderManager` wrapper,
built on the official WireGuard for iOS and macOS engine
(`wireguard-apple`, MIT).

**State: source complete. Never compiled, never signed, never run.** See
[What remains unverified](#what-remains-unverified) for exactly why, and
what is needed.

```
apple/
├── LICENSE-WireGuardApple        upstream MIT notice for the vendored code
├── Sources/
│   ├── Shared/                    vendored from wireguard-apple (MIT)
│   │   ├── Keychain.swift                     secure config storage
│   │   ├── FileManager+Extension.swift        app-group paths
│   │   ├── ErrorNotifier.swift                extension → app error relay
│   │   ├── NotificationToken.swift            KVO observer hygiene
│   │   ├── Logger.swift                       os_log + file sink
│   │   ├── String+ArrayConversion.swift       list splitting
│   │   ├── NETunnelProviderProtocol+Extension.swift   config ↔ protocol
│   │   └── TunnelConfiguration+WgQuickConfig.swift     wg-quick(5) codec
│   ├── Extension/                 the packet-tunnel provider (out of process)
│   │   ├── PhantrixPacketTunnelProvider.swift the real NEPacketTunnelProvider
│   │   └── Info.plist
│   └── App/                       the app-side plugin
│       ├── PhantrixVPNManager.swift           NEVPN lifecycle + state
│       ├── PhantrixConfigMapper.swift         JSON → TunnelConfiguration
│       └── PhantrixPlugin.swift               Flutter bridge
└── Entitlements/
    ├── PhantrixNetworkExtension_iOS.entitlements
    └── PhantrixNetworkExtension_macOS.entitlements
```

## Why this shape, and not something simpler

`NEPacketTunnelProvider` runs **out of process**, in its own sandbox,
launched by the OS. The app cannot start it directly and cannot call
into it. So there are two pieces and one channel between them:

```
Dart → method channel → PhantrixPlugin
                        → PhantrixVPNManager
                          → NETunnelProviderManager.save  ← shows the
                              OS launches the extension        consent dialog
                                → NETunnelProviderProtocol
                                  → shared keychain (private key)
                                    → WireGuardAdapter → wireguard-go
```

The private key therefore goes to the **shared app-group keychain**, not
into `providerConfiguration` — which is a plist in the VPN preferences and
is *not* encrypted. On macOS the item also carries a `SecAccess` limiting
it to the app and the extension, and is marked
`AfterFirstUnlockThisDeviceOnly`, so it is not iCloud-synchronizable.

`PhantrixVPNManager.stop` deletes that keychain item. A key that outlives
the tunnel it belonged to is a credential leak: the user believes the
connection is gone while the secret is still on disk.

## Wiring it into the Xcode project

These steps are **not** done in this repository. They are written out
because the next person with a Mac has to do them, and guessing at the
target names is how an Apple build ends up silently not working.

### 1. Add the engine as a Swift Package

`File → Add Package Dependencies…`, URL
`https://git.zx2c4.com/wireguard-apple` (mirror:
`https://github.com/WireGuard/wireguard-apple`). Add the `WireGuardKit`
product to **both** the app target and the extension target.

### 2. Build `wireguard-go-bridge` by hand

`WireGuardKit` links `wg-go` but **cannot build it** — Swift Package
Manager does not support the Make step. Create an *External Build System*
target per platform:

| Setting | Value |
| --- | --- |
| Target name | `WireGuardGoBridgeiOS` / `WireGuardGoBridgemacOS` |
| Build Tool | `/usr/bin/make` |
| Directory | `${BUILD_DIR%Build/*}SourcePackages/checkouts/wireguard-apple/Sources/WireGuardKitGo` |
| `SDKROOT` | `iphoneos` (iOS) / `macosx` (macOS) |

Then add that target as a **dependency** of the extension target, and add
`WireGuardKit` to the extension's *Link Binary With Libraries*.

> Note: the extension's Swift files `#import` the C bridge
> (`wg_log`, `open_log`, `write_msg_to_log`, …) through a bridging
> header. `Sources/Extension/` here has no `.h` of its own because the
> symbols come from the linked `WireGuardKitGo` module; if your target
> needs one, create it and set `SWIFT_OBJC_BRIDGING_HEADER`.

### 3. Create the packet-tunnel extension target

New target → *Network Extension* → **Packet Tunnel**.

| Setting | iOS | macOS |
| --- | --- | --- |
| Bundle ID | `$(PRODUCT_BUNDLE_IDENTIFIER).network-extension` | same |
| Deployment target | **iOS 15.0** or newer | **macOS 12.0** or newer |

Those minimums are the platform floor declared in wireguard-apple's own
`Package.swift`. A lower deployment target will not compile.

Copy `Sources/Extension/*` into it, set its Info.plist to the one in this
directory, and set its entitlements to the matching file in
`Entitlements/`.

### 4. Set the app's Info.plist keys

The app-group ID is read from the bundle, so it must be defined:

```xml
<key>com.phantrix.ios.app_group_id</key>
<string>group.$(APP_ID_IOS)</string>
<key>com.phantrix.macos.app_group_id</key>
<string>$(DEVELOPMENT_TEAM).group.$(APP_ID_MACOS)</string>
```

…and add the same group to the app's own entitlements, alongside
`com.apple.developer.networking.networkextension`
(`packet-tunnel-provider`). The app group must be **identical** in the
app and the extension, or nothing crosses the boundary.

### 5. Compile the app-side sources

Add `Sources/App/*` and `Sources/Shared/*` to the app target. The
extension target needs `Sources/Extension/*` **and** `Sources/Shared/*`.

`PhantrixPlugin.swift` registers the method channel
`dev.phantrix.phantrix/tunnel` and the event channel
`dev.phantrix.phantrix/tunnelEvents` — the same two the Dart layer in
`packages/phantrix_platform/lib/phantrix_platform.dart` speaks, and the
same names every other native backend uses.

### 6. Declare the platform in the plugin

Once it compiles, add to `packages/phantrix_platform/pubspec.yaml`:

```yaml
      ios:
        pluginClass: PhantrixPlugin
      macos:
        pluginClass: PhantrixPlugin
```

**This is deliberately not done yet.** Declaring a platform whose source
does not compile produces either a build failure or a stub that answers
"not supported" — a placeholder presented as a backend. The Dart layer
currently reports Apple platforms as unsupported, which is true, and
keeps saying so until this step is taken deliberately.

## What remains unverified

Nothing here has been through a compiler. Specifically:

| | Status |
| --- | --- |
| Swift sources | Written; **never compiled** |
| Xcode project wiring | **Not applied** — steps above are instructions, not executed edits |
| Signing | **Not done.** The `packet-tunnel-provider` entitlement and the app group are both capabilities that must be enabled on an Apple Developer account and reflected in a provisioning profile |
| Provisioning | **Not done.** The extension needs its own profile containing the network-extension entitlement |
| App ID / Developer Team | **Not set.** `$(APP_ID_IOS)`, `$(APP_ID_MACOS)` and `$(DEVELOPMENT_TEAM)` are placeholders for real values |
| Runtime | **Never run.** No tunnel has been started |
| Handshake | **Never completed** — no reachable peer |

The Swift API usage was checked against wireguard-apple's own sources on
`master` at the time of writing — `TunnelConfiguration(name:interface:
peers:)`, `InterfaceConfiguration(privateKey:)` with its `addresses`,
`dns` and `mtu` properties, `PeerConfiguration(publicKey:)`, the
failable `PrivateKey`/`PublicKey`/`PreSharedKey`/`IPAddressRange`/
`DNSServer`/`Endpoint` initialisers, the `WireGuardAdapter` start/stop
surface and its error cases, `NETunnelProviderManager
.loadAllFromPreferences`, and `NETunnelProviderProtocol(tunnelConfiguration:)`.
That is stronger than guessing, and it is **not** the same as compiling.

## Licence

`LICENSE-WireGuardApple` records which files are upstream's, under which
MIT licence, and reproduces the MIT text. Any file added to `Sources/`
from upstream must be added to that list in the same commit.
