# Security Policy

This document describes what Phantrix defends, what it cannot, and the
rules the code enforces. It is written to be auditable: every claim below
points at the file that implements it.

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
- Secret leakage through logs and diagnostics: keys, certificates,
	credentials, full URLs and DNS names must not escape the process in
	readable form.

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
route is a hole in that protection — which is why validation repairs
split-tunnel configs and IPv6 is blocked by default.

---

## 3. Configuration validation rules

Every configuration — from the manifest or from VPN Gate —
passes the same two gates: a parser (`WgParser` / `OvpnParser`) and a
policy validator (`WgValidator` / `OvpnValidator`). A `VpnConfiguration`
can only be constructed through those validators, so an unchecked config
cannot acquire a checked type.

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
- **IPv6 honesty:** if no peer carries an IPv6 default route, the app
	says IPv6 will be blocked while connected (`wg.peer.no_ipv6_route`) —
	it does not pretend to route it.

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
	file) ⇒ `ovpn.askpass_forbidden`; credentials are asked for at
	connection time instead.
- **TLS verification is never weakened.** A configuration with no CA at
	all — inline, file or path — is refused (`ovpn.no_ca`), because without
	it the server cannot be authenticated. There is no flag, default or
	repair that turns verification off.
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

The Windows plugin re-validates everything the bridge hands over: no payload in
error messages (it can contain key material), a missing IPv6 policy is an error
rather than a silent "allow", and a profile that asks for credentials is
refused rather than passed through. The Android plugin does not parse a request
at all — with no engine there, a start request is answered with the reason it
cannot be served.

---

## 4. Key handling

### 4.0 At rest: what the store holds, and what it does not

The app keeps one JSON file per user. It holds **settings and cached server
directories** — the chosen country, kill-switch/DNS/IPv6 preferences, the last
selected relay, and the public relay list the app last fetched. It holds **no
key material**: this build neither imports nor stores a configuration of its
own, so there is no private key on disk for anyone to find. The only
configuration that reaches a file is the VPN Gate profile the feed published,
and that is written by the engine path for the length of one tunnel and
removed when the tunnel ends (see §4.1).

What protects the file:

| Control | Detail |
| --- | --- |
| Location | the platform's own private per-user directory — `filesDir` on Android, `%LOCALAPPDATA%\Phantrix` on Windows, `$XDG_CONFIG_HOME/phantrix` or `~/.config/phantrix` on Linux, Application Support inside the app container on Apple. Never a shared or world-readable path |
| Permissions | POSIX `0700` on the directory and `0600` on the file — distinct modes, because an owner-executable bit on a JSON store is meaningless and a group-readable bit on either is not wanted. Applied explicitly after creation rather than inherited from the process umask |
| Windows | an explicit DACL for the current user and LocalSystem only, applied by the native backend on every directory creation and every file write, fail-closed. See §4.1. Deliberately **not** under `Program Files`, which is shared by every account on the machine |
| Android | `filesDir`, UID-private by the kernel; backups disabled (`allowBackup="false"`); nothing ever written to shared storage. No `chmod` is attempted there: the binary is not reliably present in an app's execution environment, so spawning it would silently do nothing on exactly the platform where silence is dangerous |
| Atomicity | written to a temporary sibling and renamed over the original, so a crash or a full disk leaves the previous file intact rather than a truncated one that fails to parse and loses the user's settings. No `.tmp` sibling is left behind after a write |

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

- **Staged to the platform: in memory only.** The validated configuration
	reaches the native side over the method channel and is handed to the
	service from a short-lived `PendingRequest` that is cleared the moment
	it is read and again on teardown. The copy in §4.0 above is the user's
	stored configuration; this is the copy handed to the engine, and it is
	not written to a second location.
- **In transit (app → platform):** keys travel inside the validated
	configuration over the method channel, and on Android the tunnel
	request is staged in a short-lived in-memory `PendingRequest` that is
	cleared the moment the service reads it and again on teardown.
- **Never in logcat:** exceptions raised while parsing or building a
	tunnel are logged by class name only. `org.json` embeds the offending
	value in its message and that value is the configuration. Passing the
	exception object to `Log` would put a private key somewhere any app
	with `READ_LOGS` (or an adb shell) can read it.
- **Never in logs:** `Redactor` (`packages/phantrix_core/lib/src/logging/redactor.dart`)
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
	`Logger` redacts at the boundary (`LogRecord.format()`), so no sink —
	memory ring buffer, stderr, or file — can receive a secret.
- **The fingerprint is 32-bit and not cryptographic.** It exists to let two
	occurrences of the same secret be correlated during support. It is
	implemented over 32-bit halves (`logging/fingerprint.dart`) because a
	64-bit integer literal cannot be represented in JavaScript and would
	break the web build. Do not mistake it for a keyed hash; do not use it
	for anything that requires collision resistance.
- **Key generation:** this build generates no WireGuard keys. When it
	does, they must come from `java.security.SecureRandom` or the platform
	CSPRNG, never `Random()`.
- **At rest (Apple): the shared keychain, and nowhere else.** Apple's
	`NETunnelProviderProtocol.providerConfiguration` is a plist in the VPN
	preferences and is *not* encrypted, so the configuration is not stored
	there. `PhantrixVPNManager` writes the wg-quick serialisation to the
	shared app-group keychain and keeps only a persistent reference in the
	protocol. On macOS the item is additionally wrapped in a `SecAccess`
	that lists the extension and the app as its only trusted
	applications, and is `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
	— not iCloud-synchronizable. `stop` deletes the item, so a key does
	not outlive the tunnel it belonged to.
- **At rest (Linux): a temporary file that does not survive the
	tunnel.** `install -m 600` places the configuration root-owned with
	0600, and `stop` removes it. There is deliberately **no** long-lived
	key store: a private key sitting in `/etc/wireguard` after the user
	disconnected is a credential left on disk.
- **On Windows:** the configuration is written to
	`%LOCALAPPDATA%\Phantrix\Phantrix.conf`, which carries an explicit DACL
	for the current user and LocalSystem only — no inherited ACEs, no other
	accounts. The service runs as LocalSystem and must read the file, which
	is why SYSTEM is on it; administrators are deliberately not, because an
	administrator can take ownership of any object regardless of its DACL
	and an ACE for them would imply a boundary that does not exist. The DACL
	is applied to the directory on creation *and* re-applied when it already
	exists, and to the file after every write, because `CREATE_ALWAYS`
	truncates without replacing a pre-existing ACL. When the DACL cannot be
	applied the file is deleted and the tunnel is refused: failing to
	connect is recoverable, a readable private key is not. The file is
	removed on teardown. Verified by launching the built app and reading the
	ACL back with `icacls`: user `(F)` plus inherit-only `(OI)(CI)(IO)(F)`,
	SYSTEM `(F)` plus inherit-only, nothing else.

---

## 4a. Privilege boundaries on Linux

Linux needs `CAP_NET_ADMIN` to create an interface, and a desktop
application does not have it. The backend's rules, all enforced by the
CI in `.github/workflows/linux.yml`:

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
	`SignatureVerifier.verifyManifest` checks the body and the list is
	labelled signed; with either half missing, or a bad length, or any
	parse failure, it returns false — never throws — and every server from
	that list carries a note that it "does not carry a signature that could
	be verified, so treat it as unverified".
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
- **"Automatic" is reconnect, not blocking.** `KillSwitchMode.automatic`
	means the app retries after a failure. Nothing holds traffic back while
	a reconnect is in flight, and the settings copy says exactly that. The
	previous wording — "as strong as the operating system allows" — was
	removed because it implied a protection that does not exist.
- **`strict` is refused out loud.** On Android, requesting it emits an event
	saying the platform cannot enforce it, and the tunnel still starts. A
	silent downgrade would leave the user believing in a guarantee nobody
	is providing.
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
	| Tunnel up, full-tunnel routes | No engine in this build; unit-tested route construction | Routed by the OpenVPN engine; one live tunnel observed (`docs/evidence/openvpn/`) | Routed by wg-quick; untested live | Routed by WireGuardKit; untested (never built) |
	| Tunnel drops unexpectedly | Traffic leaves via the normal network until reconnect, unless system lockdown is armed. Untested live | Traffic leaves via the normal network. Untested live | Traffic leaves via the normal network. Untested live | Untested (never built) |
	| Peer becomes unreachable | Handshake timeout → failure → teardown. Engine-tested config paths only; no live peer | Service reports failure; teardown removes the tunnel. Untested live | `wg-quick down` + config removal run unconditionally on failed-up. Untested live | Untested (never built) |
	| Network change / sleep-resume | Reconnect is attempted; the gap is unprotected without system lockdown. Untested live | Untested live | Untested live | Untested (never built) |
	| App killed while connected | Android keeps the service only if the system keeps it; routes die with the interface. Untested live | The service keeps running without the UI; `stop` on next launch removes it. Untested live | The interface persists until `wg-quick down`; a crash leaves it up. Untested live | Untested (never built) |
	| IPv6 with block policy | Family never added to the interface; no route to escape through. Logic-tested, untested live | Not enforced by this backend (`ipv6Block: false` is reported). **A known gap** | Enforced by dropping IPv6 routes pre-elevation. Untested live | Untested (never built) |
	| DNS during failure | Resolvers belong to the tunnel interface; on teardown the system resolver returns. Untested live | System resolver returns on service removal. Untested live | wg-quick restores resolv.conf on `down`. Untested live | Untested (never built) |

- **IPv6 handling.** Blocked by default (`Ipv6Mode.block`): on Android and
	Linux the address family is simply not added to the tunnel interface, so
	there is no IPv6 route to escape through — that is why "block" is a real
	answer rather than a leak. `prefer_tunnel` carries IPv6 only when the
	configuration declares an IPv6 default route; `allow` is labelled "may
	leak" in the settings UI. **Windows does not enforce the block policy:**
	it reports `ipv6Block: false` and the limitation is shown, because the
	OpenVPN engine applies the profile's own addresses and this backend does
	not rewrite them.
- **Verification is the only door to "connected".** An external IP probe
	compares against the pre-connection baseline; an unchanged address
	means the tunnel is not carrying traffic, and the connection is failed
	and torn down. The core state machine refuses `connected` without a
	`tunnelVerified` event, twice (`reduce` and `allows`).
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
