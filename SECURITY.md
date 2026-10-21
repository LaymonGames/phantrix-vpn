# Security Policy

This document describes what Phantrix defends, what it cannot, and the
rules the code enforces. It is written to be auditable: every claim below
points at the file that implements it.

**Current release status:** the pinned OpenVPN 2.6.17 runtime needs a security
upgrade before distribution. No strict kill switch is implemented, and DNS/IPv6
leak protection is not established by the IPv4 verification gate. See
[PROJECT_AUDIT.md](docs/PROJECT_AUDIT.md) for remaining risks and checked scope.

## 1. Threat model

**In scope:**

- A hostile local network (café Wi-Fi, hotel LAN, a compromised router):
	other devices must not be able to read traffic inside the tunnel.
- A curious ISP: it may see that you connect to a VPN endpoint, not what
	you do inside a verified full tunnel.
- A malicious or careless *configuration file*: a `.ovpn` or `.conf`
	supplied by a third party must not be able to run code on your device,
	read arbitrary files, disable authentication, or quietly exclude traffic
	from the tunnel.
- A malicious or compromised *server list*: a feed fetched over the
	network must only be able to offer servers that pass the same safety
	rules as any other profile.
- Accidental secret leakage through structured logs and diagnostics:
	keys, certificates, and credentials are filtered. Raw native engine logs
	are a separate retained surface with metadata limits described in §4.1.

**Out of scope (stated plainly):**

- **Anonymity.** Phantrix is not an anonymity tool. See the README's "No
	guarantees" section. Tor is the tool for that problem.
- **The exit server operator.** On the public relay list that is an
	unknown volunteer who can observe everything leaving their server. The
	trust label says so in the UI (`TrustLevel.publicRelay`:
	"Operated by an unknown volunteer. They can see your traffic.").
- **Endpoint compromise.** If a server is malicious, a correctly
	implemented tunnel delivers your traffic to it faithfully. That is the
	threat model transferred, not removed.
- **Application-layer tracking** performed by sites and apps through
	accounts, cookies and fingerprinting. Nothing in this repository can
	prevent it on every platform.
- **Device compromise** ( malware, a rooted phone with a hostile app).
	A VPN cannot defend against an attacker who already runs code on the
	same device.

---

## 2. What the protocols protect — and what they don't

**OpenVPN (the protocol this build runs).** Widely compatible, TLS-based,
works on networks that block UDP. It protects confidentiality and integrity
of packets inside the tunnel and authenticates the server by certificate; it
does not hide that you use a VPN (the flow itself is visible) and it provides
no anonymity beyond the exit operator. The protocol is performed by the
official OpenVPN 2 binaries on Windows: see §6. Its configuration surface is
enormous, which is exactly why the validator in §3 exists, and its security
depends on the `ca` being pinned — a configuration without a CA is refused
rather than "allowed and probably fine".

**WireGuard (in the tree, on no path the app can take).** The domain library
still parses and validates WireGuard configurations (§3.1), and the Linux and
Apple platform sources still drive WireGuard engines, but the app never sends a
WireGuard configuration and never reads a WireGuard capability: every build
declines a WireGuard server by name. That code is kept because it is tested and
inert, not because anything can reach it.

**Both share the same structural limits:** they protect the wire, not the
exit. Whichever server you choose, its operator sees your decrypted
traffic. IPv6 outside the tunnel, DNS outside the tunnel, or any split
route is a hole in that protection. Validation repairs client-side default
routes, but this is not a firewall. The default IPv6 preference does not prove
host-level blocking; see §6.

---

## 3. Configuration validation rules

Every configuration — from the manifest or from VPN Gate —
passes the same two gates: a parser (`WgParser` / `OvpnParser`) and a
policy validator (`WgValidator` / `OvpnValidator`) on the app's ingestion path.
The public Dart model constructors are not a security boundary by themselves:
callers can construct values directly. The elevated Windows helper independently
validates the complete serialized profile before starting the engine.

### 3.1 WireGuard (`packages/phantrix_core/lib/src/protocol/wireguard/wg_validator.dart`)

- **Script directives are forbidden outright.** `PreUp`, `PostUp`,
	`PreDown`, `PostDown` anywhere in the file ⇒ rejection with
	`wg.forbidden_directive`. A config file must never run commands; other
	unknown directives are recorded and reported as ignored, never executed.
- **Private key format is enforced:** exactly 44 base64 characters (32
	bytes) ending in `=` (`wg_key.dart`); anything else is `wg.interface.private_key`.
- **At least one interface address, at least one peer**, every peer needs
	a public key, an endpoint and `AllowedIPs` — missing any ⇒ rejection.
- **Default-route repair:** a peer without `0.0.0.0/0` (or `::/0`) is
	expanded by `applyFullTunnel`, then re-validated. A split-tunnel config
	cannot silently become a leaky one; the repair is surfaced to the user
	(`routeRepair`, and "Phantrix will add 0.0.0.0/0 so traffic cannot
	leave outside the tunnel").
- **IPv6 warning:** a missing IPv6 default route produces
	`wg.peer.no_ipv6_route`. That warning is not proof of host-level blocking.
	This parser is not on the app's active connection path.

### 3.2 OpenVPN (`packages/phantrix_core/lib/src/protocol/openvpn/ovpn_validator.dart`)

- **Execution directives are fatal.** `up`, `down`, `route-up`,
	`tls-verify`, `ipchange`, `client-connect`, `client-disconnect`,
	`learn-address`, `auth-user-pass-verify`, `plugin`, `config`, `cd`,
	`chroot`, `daemon`, `ifconfig-noexec`, `route-noexec`, `management`,
	`management-client`, `status`, `log`, `log-append`, `machine-id` ⇒
	`ovpn.forbidden_directive`. `script-security 2` ⇒ `ovpn.script_security`.
- **No external files.** `ca`, `cert`, `key`, `dh`, `pkcs12`,
	`tls-auth`, `tls-crypt`, `tls-crypt-v2`, `extra-certs`, `crl-verify`,
	`http-proxy-user-pass` must be inline blocks; a path on disk ⇒
	`ovpn.external_file_forbidden`. `askpass` (reading credentials from a
	file) ⇒ `ovpn.askpass_forbidden`. This build has no user-credential
	prompt; the Windows helper refuses profiles requiring one.
- **TLS verification is never weakened.** A configuration with no CA at
	all — inline, file or path — is refused (`ovpn.no_ca`), because without
	it the server cannot be authenticated. There is no flag, default or
	repair that turns verification off.
- **Server identity is preserved:** serialization always emits
`remote-cert-tls server` and preserves explicit `verify-x509-name`,
`key-direction`, and supported TLS policy options. A server certificate
without the required server usage may now be refused rather than accepted.
- **Broken crypto is refused, not warned about:** ciphers with no
	confidentiality (`none`, DES, 3DES, RC2, BF, RC4 variants) ⇒
	`ovpn.broken_cipher`; non-collision-resistant digests (`md4`, `md5`,
	`rmd160`, `none`) ⇒ `ovpn.broken_auth`.
- **Leak-shaped routing is refused:** no `remote` ⇒ error; `route-nopull`
	*without* `pull` ⇒ `ovpn.route_nopull` (server routes blocked and none
	pulled means traffic leaves outside the tunnel). A missing `pull` or
	`redirect-gateway` is a *warning plus a repair* ("Phantrix will force
	one"), and every repair is listed to the user — nothing is modified
	silently.
- **Layer 2 is refused:** `dev tap` ⇒ `ovpn.tap_unsupported`; Phantrix
	routes layer 3.
- **A remote host must be a real host.** `_validHost` accepts a dotted
	IPv4 address only when each octet is in range, accepts a bare IPv6
	literal, and accepts a domain name only when every label is 1–63
	characters, starts and ends with an alphanumeric or underscore, and
	permits hyphens *only in the interior* of a label. That last rule is
	a fix: the previous pattern, `[A-Za-z0-9_-]{1,63}`, permitted a
	**leading hyphen**, which RFC 1123 forbids and which can never
	resolve. The final label must also contain a letter, so a truncated
	address such as `192.0.2` is refused as a hostname rather than
	accepted as a name it can never be. `ovpn_host_validation_test.dart`
	covers IPv4, each malformed form, DNS names, IPv6 literals, and the
	supported configuration syntax.
- **Client identity must be complete:** `cert` without `key` (or vice
	versa) is an error, and an inline `key` block must actually look like a
	PEM private key.
- Remote hostnames and ports are validated (syntax, 1–65535).

### 3.3 Request validation at the backend

The Windows helper accepts only the normalized serializer's directive subset,
inline certificate/key material, a client TUN profile, and server-certificate
verification. It reads and checks the entire profile, rejecting anything over
64 KiB instead of checking a safe prefix. Session paths must exactly match fixed
filenames beneath the generated session directory. Directory/profile handles
are held against replacement while the engine uses them, with reparse-point and
hardlink checks on session files. Native regression tests cover these rules.

This does **not** mean every request preference is enforced: Windows does not
implement the requested strict kill switch, custom DNS, MTU, or host IPv6 block.
The Android plugin has no engine and rejects a start request explicitly.

---

## 4. Key handling

### 4.0 At rest: what the store holds, and what it does not

The settings JSON holds preferences and selected/recent/favourite relays.
Separate files cache public directory metadata and VPN Gate OpenVPN profiles.
Those profiles can contain the feed's **shared client private keys**. They are
public feed data, not user-owned account credentials, but they are still key
material on disk; base64 storage is not encryption.

Windows also writes a restricted per-session profile and public VPN Gate
authentication file. Normal teardown removes session files, after retaining
bounded raw OpenVPN log archives. A crash can leave session files behind;
cleanup is not a secure-erasure guarantee. See §4.1 and [PRIVACY.md](PRIVACY.md).

What protects the file:

| Control | Detail |
| --- | --- |
| Location | the platform's own private per-user directory — `filesDir` on Android, `%LOCALAPPDATA%\Phantrix` on Windows, `$XDG_CONFIG_HOME/phantrix` or `~/.config/phantrix` on Linux, Application Support inside the app container on Apple. Never a shared or world-readable path |
| Permissions | The settings store attempts POSIX `0700` on newly created directories and `0600` on files. Permission-command failures are currently best effort, not a fail-closed guarantee for every Dart cache |
| Windows | Native session directories/files receive an explicit current-user + LocalSystem DACL, fail-closed. Dart settings/cache files rely on the per-user directory; do not infer that every Dart write reapplies the native file ACL |
| Android | `filesDir`, UID-private by the kernel; backups disabled (`allowBackup="false"`); nothing ever written to shared storage. No `chmod` is attempted there: the binary is not reliably present in an app's execution environment, so spawning it would silently do nothing on exactly the platform where silence is dangerous |
| Atomicity | Writes use a temporary sibling and rename over the original rather than deleting the good file first. Failed settings writes no longer poison the next queued write. Ordinary failure cleanup removes temporary files; process crashes can still leave them |

What is **not** claimed:

- **Not encrypted at rest.** There is no keystore integration on desktop. A
  "secure store" that silently degrades to a plain file on some platforms would
  be worse than an honest one, so there is not one.
- **No protection from malware or another process running as the same user.**
  Anything that can read the user's files can read this one.
- **Administrators can take ownership of anything.** The Windows DACL keeps
  other standard users and services out; it cannot keep out an administrator,
  and it does not claim to.
- **The web persists nothing.** `openDefaultStore` returns an in-memory store
  when the platform reports no private directory, so settings there live for
  the session only.

#### Android Keystore assessment

Encrypting the store file with a key protected by Android Keystore was
assessed and deliberately not implemented, for these reasons:

1. **Threat coverage is narrow.** On a non-rooted device `filesDir` is already
   UID-isolated by the kernel and SELinux, backups are off, and nothing leaves
   the sandbox — there is no reader for encryption to stop. Keystore
   encryption only helps against file extraction from a *rooted* device with
   hardware-backed keys, and against nothing else.
2. **Key-management risk is real.** A Keystore key that becomes unusable
   (hardware reset, verified-boot state change, key corruption) locks the user
   out of every stored setting at once. A mechanism that converts a
   recoverable failure into simultaneous loss of everything the app remembers
   needs the rest of the product (backup, export, recovery flows) to exist
   first, and they do not.
3. **The failure mode must not be a silent downgrade.** An "encrypted store"
   that falls back to plain text when the Keystore is unavailable is worse
   than a plain store that says so, because it teaches the user a protection
   exists that comes and goes.

The correct time to revisit this is when the product has export/recovery
flows and a reason to survive device compromise beyond what the sandbox
provides. Until then the sandbox, the disabled backups, and the documented
plaintext are the honest posture — and the assessment is recorded here rather
than left as an unasked question.

**Release builds never embed a key.** `tools/check_windows_build.ps1` asserts
that no `BEGIN PRIVATE KEY` block appears in the built binary, because a key
shipped in an artifact is a key given to everyone who downloads it.

### 4.1 In transit and in logs

- **Staged to the platform:** the configuration travels over the local method
	channel. Windows writes it into its restricted session directory for the
	OpenVPN subprocess; it is not memory-only. Android has no tunnel engine in
	this build and does not provide the former `PendingRequest` service path.
- **Never in logcat:** exceptions raised while parsing or building a
	tunnel are logged by class name only. `org.json` embeds the offending
	value in its message and that value is the configuration. Passing the
	exception object to `Log` would put a private key somewhere any app
	with `READ_LOGS` (or an adb shell) can read it.
- **Structured application logs:** `Redactor` (`packages/phantrix_core/lib/src/logging/redactor.dart`)
	runs every log field through, at minimum:
	- WireGuard base64 keys → non-reversible `[redacted-…]` marker
	carrying an 8-hex-character FNV-1a fingerprint, so the same secret
	is correlatable during support without being revealed — see the
	caveat below on its strength;
	- PEM blocks (certificates, keys) → `[redacted]`;
	- credential assignments (`auth-user-pass`, `password`, `secret`,
	`token`, `presharedkey`, `privatekey`, `psk`, `username`, …) →
	`key: [redacted]`;
	- full URLs → `scheme://host/…` (path and query can leak DNS identity);
	- IPv6 addresses → truncated to the /48 prefix.
	`Logger` redacts at the formatting boundary. This is tested secret
	filtering, not a guarantee that arbitrary input cannot reveal metadata.
- **Raw native logs are separate:** Windows retains up to three OpenVPN log
archives, each holding up to 512 KiB of engine output plus a trim marker,
beneath `%LOCALAPPDATA%\Phantrix\logs\`. They bypass the Dart redactor and may
contain endpoint addresses, names, and connection metadata. Do not share
them without review. The in-app clear-log action does not delete them.
- **The fingerprint is 32-bit and not cryptographic.** It exists to let two
	occurrences of the same secret be correlated during support. It is
	implemented over 32-bit halves (`logging/fingerprint.dart`) because a
	64-bit integer literal cannot be represented in JavaScript and would
	break the web build. Do not mistake it for a keyed hash; do not use it
	for anything that requires collision resistance.
- **Key generation:** this build generates no WireGuard keys. When it
	does, they must come from `java.security.SecureRandom` or the platform
	CSPRNG, never `Random()`.
- **Apple source design (uncompiled, not a supported target):** Apple's
	`NETunnelProviderProtocol.providerConfiguration` is a plist in the VPN
	preferences and is *not* encrypted, so the configuration is not stored
	there. `PhantrixVPNManager` writes the wg-quick serialisation to the
	shared app-group keychain and keeps only a persistent reference in the
	protocol. On macOS the item is additionally wrapped in a `SecAccess`
	that lists the extension and the app as its only trusted
	applications, and is `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
	— not iCloud-synchronizable. `stop` deletes the item, so a key does
	not outlive the tunnel it belonged to.
- **Inert Linux WireGuard source:** `install -m 600` places the configuration root-owned with
	0600, and `stop` removes it. There is deliberately **no** long-lived
	key store: a private key sitting in `/etc/wireguard` after the user
	disconnected is a credential left on disk.
- **On Windows:** the configuration is
	`%LOCALAPPDATA%\Phantrix\openvpn\session-<token>\phantrix.ovpn`.
	The helper is an elevated process for the user, not a LocalSystem service.
	Native file/directory ACLs allow the current user and SYSTEM; inability to
	secure the profile refuses the tunnel. Administrators can still take
	ownership. The helper locks the checked profile against writes/deletion
	until the engine stops. Normal teardown removes the session directory;
	crash recovery and helper-child lifetime still need fault-injection tests.

---

## 4a. Privilege boundaries on Linux

Linux needs `CAP_NET_ADMIN` to create an interface, and a desktop
application does not have it. This legacy WireGuard backend is not on the
OpenVPN-only app's supported connection path. The following describes source
intent and CI compile/static checks, not a live audit of privilege handling:

- **No shell.** `runElevated` executes `pkexec` through `posix_spawnp`
	with an argument vector. There is no `/bin/sh -c`, so no character
	inside any argument can terminate the argument or start a new
	command. This replaced an implementation that built a command string
	and passed it to `std::system`; the workflow **fails** if
	`std::system` reappears, because that pattern's safety depended on
	the arguments happening to be constrained rather than on the code
	being structured so they cannot matter.
- **One command, one purpose.** `install`, `wg-quick up`, `wg-quick
	down` and `rm` are each elevated separately. Nothing else runs as
	root, there is no helper daemon, no cached credential, and no
	password piped into `sudo`.
- **The configuration is defended independently of the shell.** The
	values are written to a file that `wg-quick` reads *as root*, so a
	newline inside a value could append a `PostUp` directive and gain
	root command execution through wg-quick itself. `renderConfig`
	strips `\n`, `\r` and NUL from every value for that reason, and it
	is the most important defensive check in that file.
- **Failure is discriminated.** `pkexec` exit code 126/127 is reported
	as `permission.denied`; every other failure is `tunnel.failed`. The
	two need opposite responses from the user, and conflating them would
	either blame the server for a user pressing Cancel or blame the user
	for a server that is down.
- **No automatic system changes.** No CI job elevates anything. The
	plugin is compiled there, not run.

---

## 5. Server-list trust

- **Transport:** server lists are fetched only over HTTPS.
	`ManifestProvider` refuses a non-HTTPS endpoint outright
	(`manifest.insecure_url`), and `HttpFetcher` implementations must
	re-validate the scheme after any redirect and cap the response body
	(`maxBodyBytes`, enforced via `BodyTooLargeException`) so a hostile feed
	cannot exhaust memory.
- **Transport, in this app:** all four of those rules live in one place,
	`lib/net/app_http_fetcher.dart`, which is the only class in `lib/` that
	opens an outbound connection. Concretely:
	- a `http://` URL throws `http.plaintext_rejected` before any socket is
	  opened, with no development-mode escape hatch;
	- a redirect to `http://` throws `http.plaintext_redirect`, so a
	  compromised feed cannot downgrade the transport;
	- a body over `maxBodyBytes` throws `http.body_too_large`;
	- non-UTF-8 bytes are rejected rather than replaced with U+FFFD, which
	  would parse into nonsense country names;
	- **certificate verification is never disabled.** The stock
	  `package:http` client is used untouched. There is no
	  `badCertificateCallback`, no custom `SecurityContext`, and no trust-all
	  branch anywhere in the repository.
	- Failures are converted into `AppError`s whose message never contains a
	  hostname, URL path or response content, because a socket exception
	  carries the hostname and that is connection metadata.
- **Signing:** manifests may ship a detached Ed25519 signature. With both
	a `signatureUrl` and the matching base64 public key configured,
	`SignatureVerifier.verifyManifest` checks the exact response body.
	Configuring either signing field requires verification: missing halves,
	bad signatures, or signature-fetch failures reject the refresh with
	`manifest.signature_invalid`. An explicitly unsigned source may still
	offer validated entries, but cannot grant itself project/community trust.
	Document content cannot assert its own verified-signature status.
- **Trust levels** (`model/trust_level.dart`) are about the exit point,
	not the cipher, and three of them (`publicRelay`, `imported`,
	`unknown`) always carry a warning in the UI:
	- `projectVerified` — run by this project and audited (none exist yet);
	- `community` — reviewed operator;
	- `publicRelay` — unknown volunteer; they can see your traffic;
	- `imported` — the enum value for a configuration the user supplied; this
		build has no import path, so nothing produces it, and it stays
		described rather than deleted along with the code it belongs to;
	- `unknown` — no information.
- **Filtering under trust:** even a *signed* manifest cannot smuggle in a
	dangerous configuration — every entry passes the identical
	parse/validate/repair/re-validate path, whatever its source. Trust levels
	change what the app *says* about a server, never what it will *accept*.

---

## 6. Honest limits

- **No backend here can block traffic itself when the tunnel drops.**
	`supportsKillSwitch` is false on every platform, and that is a statement
	of fact, not a missing flag. None of the backends installs a
	traffic-blocking rule that survives the tunnel interface: not Android
	(no userspace API exists for one on stock Android), not Windows (no
	firewall rule is added, by design), not Linux (no nftables/iptables rule
	is added, by design), not Apple (no `includeAllNetworks` content-filter
	posture is implemented). A settings control that claimed otherwise would
	be the single most dangerous lie in the product, so the control reports
	the limitation instead.
- **"Automatic" is not blocking.** Connection retries and engine reconnects
	can happen, but this preference is not a complete failure-recovery
	supervisor and holds no traffic back during a reconnect.
- **`strict` is unsupported.** Capabilities report no backend enforcement.
	Windows does not turn the request into firewall rules. Android has no
	engine and refuses tunnel starts, irrespective of this preference.
- **Android's genuine protection is the system's, and it is read live.**
	Always-on VPN with "Block connections without VPN" is the only traffic
	blocker on stock Android. The app reads `always_on_vpn_app` and
	`always_on_vpn_lockdown` from `Settings.Secure` on every settings-screen
	build and shows whether lockdown is actually armed for this app, with a
	link to the system screen that controls it. A cached answer would report
	protection that the user may have switched off, so it is never cached.
- **Leak behaviour by scenario, as far as it is known.** "Untested" means
	exactly that — not "safe", not "leaking", but not measured:

	| Scenario | Android | Windows | Linux | Apple |
	| --- | --- | --- | --- | --- |
	| Tunnel up | No engine | Historical IPv4 tunnel evidence in `docs/evidence/openvpn/`; not a fresh audit run | No app-supported engine; inert WireGuard source | Not wired or compiled |
	| Tunnel drops / reconnects | No engine | No firewall blocks fallback traffic | Not tested live | Not built |
	| Peer unreachable / sleep-resume | No engine | Fault and recovery behavior needs live testing | Not tested live | Not built |
	| App or helper killed | No engine | Helper watches parent, but child lifetime after helper crash is not guaranteed; no kill-on-close job | Inert source can leave a WireGuard interface behind | Not built |
	| IPv6 with block preference | No engine | Host-level block not enforced (`ipv6Block: false`) | Omitting tunnel IPv6 routes does not block the physical network | Not built |
	| DNS protection / failure | No engine | Not verified; no independent DNS-leak firewall | Not tested live | Not built |

- **IPv6 handling.** `Ipv6Mode.block` is the default preference, not proof
	of enforcement. OpenVPN's serialized `block-ipv6` only blocks IPv6 that
	reaches the TUN device. Removing or omitting tunnel IPv6 routes does not
	block IPv6 on a physical adapter. Separate routing/firewall enforcement
	and packet-level tests are needed before claiming IPv6 leak protection.
- **Verification gates "connected".** A recent, non-future handshake plus
	a changed public address in the baseline's IP family is required. A
	missing baseline or unchanged/unavailable probe fails closed and requests
	teardown; teardown errors remain visible. The default probes measure IPv4
	only. Success does not establish DNS, IPv6, every application's routing,
	or protection after a drop. The core state machine requires
	`tunnelVerified` in both `reduce` and `allows`.
- **The redactor once leaked, and now pins absence.** The credential rule
	replaced `password=hunter2` with `hunter2: [redacted]` — the secret,
	printed next to the marker claiming its removal — and a scoped
	case-insensitive flag silently failed to match `PresharedKey` at all, so
	preshared keys were never redacted. Both were found by asserting that the
	secret is *absent* from the output, which the old tests never did: they
	checked only that a marker was present, and pass on leaking output too.
	The regression tests now assert absence for every credential form, and
	the case-insensitivity comes from a flag that matches uniformly.
- **No anonymity, still.** Everything above protects the path, not the
	destination. The exit operator — for public relays, a stranger — sees
	your traffic.
- **The protocol engine is real, and it is third-party.** Windows drives the
	official OpenVPN 2 community binaries as a separate process, which perform
	the TLS handshake, key exchange and packet routing; Linux drives the
	kernel's own WireGuard through `wg-quick`. Phantrix implements no VPN
	cryptography and never will: reimplementing a VPN protocol is precisely
	the risk this project refuses to take. The Windows bundle is fetched from
	the official source and pinned by SHA-256 before it is unpacked.
- **What is not implemented:** there is no tunnel for Android, iOS, macOS or
	web. The one live tunnel recorded here is Windows/OpenVPN
	(`docs/evidence/openvpn/`), where the exit address changed and traffic
	flowed for minutes; everything else in this document is a claim about the
	code. The security-critical surfaces that do exist and are tested are the
	validators, the redactor, the full-tunnel repair, the state machine, the
	selection resolver and the verification gate.
---

## 7. Reporting a vulnerability

Please **do not** open a public issue for a security problem.

- Email **gamesbylaymon@gmail.com** — Laymon Games, the project maintainer.
- Include: affected file(s) and function(s) as listed in this document's
	references, a description of the impact, and reproduction steps or a
	proof of concept.
- Please allow **90 days** for a fix before public disclosure, and give
	us the chance to ship the fix to users first.
- We will acknowledge receipt within 7 days.

Reports about *documentation claiming something the code does not do*
are welcome as ordinary issues and are treated as seriously as bugs: a
doc that overstates a protection is a security bug.
