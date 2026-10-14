# Phantrix

Phantrix is a free, vibe-coded, account-free VPN client for **WireGuard** and **OpenVPN**,
built with Flutter. There is no sign-up, no subscription and no analytics.
It is a client only: you bring a server (your own, your provider's, or a public
relay from the built-in VPN Gate list).

Phantrix's own code is licensed under **GPL-3.0-only** (see [License](#license)).

> **Status: early and mostly unverified.** An OpenVPN tunnel has been observed
> working once on Windows. No WireGuard handshake has ever been observed on any
> platform. Read [Platform status](#platform-status) before relying on it.

---

## Quick start (build from source)

These steps are for **Windows**, the only platform where the built-in VPN Gate
relays can connect. Other platforms are covered in [BUILDING.md](BUILDING.md).

**You need:** Flutter (3.47.0 or newer), and Visual Studio 2022 with the
"Desktop development with C++" workload.

From the repository root, in a normal Windows terminal:

```powershell
flutter pub get

# Downloads the OpenVPN engine and the wintun driver, and verifies their
# pinned SHA-256 hashes. Required for OpenVPN and the VPN Gate relays.
powershell -NoProfile -ExecutionPolicy Bypass -File tools\fetch_openvpn_bundle.ps1

flutter run -d windows            # or: flutter build windows --release
```

Notes:

- **Do not skip the fetch step.** The OpenVPN engine is deliberately *not* in
  git (everything under `packages/phantrix_platform/windows/bundle/` is
  ignored). A checkout without it still builds, but the app reports OpenVPN as
  unavailable and cannot connect to relays or `.ovpn` files, so it looks like
  "nothing happens" when you press Connect.
- If you already built before fetching, run `flutter clean` and build again so
  CMake picks up the new files.
- To re-check the downloaded files without downloading anything, add
  `-VerifyOnly` to the fetch command.
- The command uses the PowerShell that ships with Windows. PowerShell 7
  (`pwsh`) is not required.
- OpenVPN connections ask for administrator approval (a UAC prompt) because the
  engine runs in a separate elevated helper. The app itself is not elevated.
- WireGuard on Windows uses the official **WireGuard for Windows** service. It
  must be installed, and the app must be run as Administrator.

## Using it

- **WireGuard:** open **Home → Import** (or **Settings → Configurations**) and
  paste or pick a `.conf` file. It is parsed and validated before it is saved.
  Files that contain `PreUp`/`PostUp`/`PreDown`/`PostDown` are refused, because
  those run commands on your machine.
- **OpenVPN:** Windows only. Pick a relay from the VPN Gate list or import an
  `.ovpn` file. The profile is validated before the engine sees it.
- Imported configurations contain your private key and are stored in the
  app's per-user data directory without extra encryption by Phantrix.

Phantrix reports **Connected** only after the engine confirms a completed
handshake **and** your public address has changed. Otherwise it says why it is
not connected rather than showing a green tick.

---

## Platform status

| Platform | WireGuard | OpenVPN | Verified |
| --- | --- | --- | --- |
| Android | Official `com.wireguard.android:tunnel` library | **None** (see [License](#license)) | Recorded: engine and app tests pass on an Android 14 emulator. No handshake observed |
| Windows | Official WireGuard for Windows service | Official OpenVPN 2.6 binaries + wintun, run as a separate helper process | OpenVPN: one live tunnel observed, 6.5 minutes, exit address changed (`docs/evidence/openvpn/`). WireGuard: built, never run |
| Linux | `wg-quick` / kernel module, elevated with `pkexec` | None | Compiled in CI. Never run on a live system |
| macOS / iOS | Not supported | None | Apple source exists in `packages/phantrix_platform/apple/` but has never been compiled and is not a build target |
| Web | Not possible | Not possible | A browser cannot tunnel system traffic. The app builds, and Connect fails explicitly |

"Official engine" means Phantrix uses the upstream engine and implements no VPN
cryptography itself. It is not a claim that a tunnel has been verified.

The public VPN Gate relays publish OpenVPN profiles only, so on Android and
Linux they are listed but cannot be connected. Relays are run by volunteers and
may be unreachable from your network.

Android release builds are **debug-signed** unless you provide your own upload
key; see [BUILDING.md](BUILDING.md).

## What a VPN does and does not do

A VPN hides your traffic from the local network and your ISP, and shows sites
the server's address instead of yours. It does **not** make you anonymous: the
operator of the exit server can see the traffic that leaves it, and for public
relays that operator is an unknown volunteer. It also does not protect your
accounts, your device, or you from application-level tracking.

Other limits worth knowing: the strict kill switch is reported as unsupported on
Android, and IPv6 is blocked by default.

## Privacy

No account, no analytics SDK, no crash reporter. The app fetches the VPN Gate
server list and checks your public address (via ipify and Amazon's
`checkip` service) to verify the tunnel. See [PRIVACY.md](PRIVACY.md) for
exactly what is stored and how to delete it.

---

## Development

```bash
flutter pub get
flutter analyze
flutter test

cd packages/phantrix_core && dart pub get && dart test
```

After any dependency change, regenerate the in-app license list and commit the
result:

```bash
dart run tools/generate_third_party_notices.dart
```

Layout: `lib/` (Flutter UI), `packages/phantrix_core/` (protocol parsing,
validation, discovery, state machine), `packages/phantrix_platform/` (native
tunnel code per platform). See [ARCHITECTURE.md](ARCHITECTURE.md).

## Documentation

| File | Covers |
| --- | --- |
| [BUILDING.md](BUILDING.md) | Toolchains and per-platform build steps |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Package layout and the platform bridge |
| [SECURITY.md](SECURITY.md) | Threat model, validation rules, reporting a vulnerability |
| [PRIVACY.md](PRIVACY.md) | What is stored and what is not collected |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Workflow and PR checklist |
| [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md) | Dependencies and bundled components, with licenses |
| [docs/LICENSING_AUDIT.md](docs/LICENSING_AUDIT.md) | GPL-3.0 compatibility review |
| [docs/EVIDENCE.md](docs/EVIDENCE.md) | What was verified, how, and what is still open |

## License

Phantrix's original code is licensed under the **GNU General Public License
v3.0 only** (`GPL-3.0-only`). See [LICENSE](LICENSE) for the license text and
[COPYRIGHT](COPYRIGHT) for the notice. The license applies to independently
authored code; third-party and adapted code keeps its own license, listed in
[THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md) and in the app under
**Settings → About, licenses and credits**.

- **Windows bundle:** the OpenVPN 2 community engine (GPL-2.0) runs as a
  separate, unmodified process, which is aggregation rather than a combined
  work. The wintun driver is under WireGuard LLC's prebuilt-binaries license and
  must stay unmodified and paired with OpenVPN. Neither is committed to this
  repository; they are downloaded by `tools/fetch_openvpn_bundle.ps1`.
- **Android:** there is no OpenVPN engine, because the only available one
  (ics-openvpn) is GPL-2.0-only and cannot be combined with GPL-3.0 code. Do
  not add it, or other GPL-2.0-only code, to the Android build.

This is an engineering review, not legal advice.
