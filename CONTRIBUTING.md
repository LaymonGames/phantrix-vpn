# Contributing to Phantrix

Thank you for helping. Working on a VPN client means the project's first
loyalty is to the user's safety, and its first rule is honesty: **never
claim untested functionality.** A contribution that works is welcome; a
contribution that pretends is not, no matter how good it looks.

## 1. Development workflow

```bash
# Domain layer — the gate everything must pass
cd packages/phantrix_core
dart pub get
dart analyze          # must be clean (strict-casts, strict-inference)
dart test             # 150 core tests as of this writing

# Plugin Dart layer
cd ../phantrix_platform
flutter pub get
flutter analyze       # must be clean

# Root app
cd ../..
flutter pub get
flutter run -d <device>
```

Current baseline you should match or improve: `phantrix_core` and
`phantrix_platform` analyze clean; `phantrix_core` has 117 passing tests.
`flutter analyze` at the root reports issues in the UI code that is
still landing under `lib/` (17 at the time of writing); finishing that
wiring is welcome work, but do not add new issues to the two clean
packages.

## 2. Commit style

- One logical change per commit. Refactors and behaviour changes go in
	separate commits.
- Subject in the imperative, under ~72 characters, with a scope prefix:
	`core: reject script-security 2 in OpenVPN configs`,
	`android: stage tunnel request without secrets in the Intent`,
	`docs: correct kill-switch claim for Android`.
- Body explains **why**, with links to issues/PRs. If the commit changes
	user-visible behaviour, say what the user will now see.
- Never commit: keystores, `key.properties`, `local.properties` with your
	machine paths, real server credentials, or logs that could contain one.
- If a commit is a work in progress, say so in the body. Do not describe
	intent as fact — "adds X" must mean X exists and works, not that the
	scaffolding for X exists.

## 3. Code style

- **Tabs** for indentation, everywhere: Dart, Kotlin, YAML. The whole
	repository uses tabs; match the file you are editing.
- **Strong typing.** The core analyzes with `strict-casts` and
	`strict-inference`; `avoid_dynamic_calls` is on. Fields are `final` by
	default; `AppSettings`, `DirectorySnapshot`, `ConnectionSession` and
	friends are immutable with `copyWith` so a half-updated state can never
	be rendered. No `dynamic` unless a platform payload forces it, and then
	narrow it immediately.
- **Every public member has a return type** (`always_declare_return_types`),
	and doc comments explain the *rule*, not the restatement of the
	signature (`comment_references` is on — reference real identifiers).
- **Errors are values.** `Result<T>` with `AppError`; the core never
	throws across a boundary, and error codes are stable strings
	(`wg.handshake_timeout`, `ovpn.external_file_forbidden`,
	`manifest.insecure_url`, `permission.revoked`) so the UI, logs and
	tests share one vocabulary.
- **Logs are redacted by construction.** Anything that may touch a log
	passes through `Redactor`. If you add a new field that could contain a
	secret, add it to the redactor and a test, in the same commit.
- **No TODOs in core VPN paths.** A TODO in a validator, the state
	machine, a provider or the bridge is a hole in a security boundary.
	Either implement it or file an issue and leave the code honest.
- **No placeholder methods that pretend to work.** A function that
	returns a plausible-looking value because the real behaviour is not
	implemented yet is worse than a missing function: it converts a known
	gap into a silent lie. Return an explicit error, report the capability
	as unsupported (`PlatformCapabilities`, `AndroidCapabilities`,
	`CheckStatus.notTested` all exist for exactly this), or do not write
	the function yet.

## 4. Adding a new ServerProvider

Implement `ServerProvider`
(`packages/phantrix_core/lib/src/providers/common/server_provider.dart`)
and follow the contract in its doc comment and in
`packages/phantrix_core/test/providers/`:

1. **Never throw from `refresh()`.** Transport failures come back as
	`RefreshOutcome.failure(error)`; a parse failure is a failure, not an
	empty list.
2. **Validate before offering.** Parse every configuration and run the
	matching validator (`WgValidator` / `OvpnValidator`) *before* a server
	is emitted, exactly as `VpnGateProvider._accept` does. A row you
	cannot use must not appear in the list, so the advertised count is the
	real count.
3. **Never fabricate a status, latency or score.** Report what the feed
	said, and let `ServerScorer` rank it.
4. **Declare the trust relationship** with `trustDescription` and assign
	a `TrustLevel` that is true. If users need a warning to protect
	themselves, the label must carry it.
5. **HTTPS only**, through an injected `HttpFetcher` with its body cap
	enforced. If your endpoint can be reached over plain HTTP, reject it
	with a named error code, as `ManifestProvider` does.
6. **Test it**: a fake `HttpFetcher` (see `vpn_gate_parser_test.dart`,
	`manifest_provider_test.dart`) covering the happy path, a malformed
	body, a config that fails validation, and the trust labelling. Then
	register the provider wherever the discovery layer is assembled.

## 5. Adding a new platform tunnel

The layers, in order:

1. **Dart side (`packages/phantrix_platform/lib/phantrix_platform.dart`).**
	The channel names, method set, `TunnelRequest` shape and event payload
	are already defined — do not fork them. Map platform errors onto the
	existing stable codes (`wg.*`, `ovpn.*`, `permission.*`, `server.*`,
	`dns.*`) and onto `AppError` groups.
2. **Native side** (new `android/…`, `ios/…`, `linux/…`, `macos/…`,
	`windows/…` directory in the plugin), implementing:
	- `capabilities` — honestly. Every boolean is a fact about the OS, not
		an intention; unknown means unsupported, and limitations are
		human-readable explanations.
	- `requestPermission` — the OS's own consent flow. False on refusal,
		never a crash.
	- `startTunnel` — parse the request with the same strictness as
		`TunnelRequestParser` (no defaults that could mean "allow", no
		payload in error messages), bring up the tunnel, and remember that
		reporting the interface as up is *not* reporting success.
	- `stopTunnel` — always cleans up, even after a mid-connect crash.
	- the event stream — including a replay of current state to late
		subscribers, as `EventChannelListener` does.
3. **The state machine rules are not negotiable.** `connected` is reachable
	only through `tunnelVerified`; verification means an external check that
	traffic really leaves through the tunnel (see `LeakCheck` in
	`lib/vpn/connection_controller.dart` and `VpnStateMachine.allows`). A
	platform that cannot verify must not be able to claim connected.
4. **Crypto stays native.** Embed a vetted engine (Android: the Apache-2.0
	`com.wireguard.android:tunnel`); never hand-roll Noise, ChaCha20 or
	TLS.
5. **Keys** are never written to logs, never passed through `Intent`
	extras, and in this build never written to disk at all. When
	persistent tunnels are added, the wrapping key must be non-exportable
	and live in the platform keystore (`KeystoreKeyStore`-style, `javax.crypto`
	only) — never a value you can read back.
6. **Document the platform's real limits** in the same commit — kill-switch
	strictness, IPv6 handling, always-on behaviour, tray, boot start.
	A platform that cannot do something reports `limitations`.

## 6. Platform limitations are reported, not approximated

This is the rule that keeps the project trustworthy, so it is a rule
about *behaviour*, not just comments:

- If the OS cannot enforce a strict kill switch, report `strict` as
	unsupported (`RoutingPolicy.killSwitchStatus` is the reference
	implementation) — do not ship a switch that does nothing.
- If IPv6 cannot be carried, block it and say so (`Ipv6Mode.block`).
	"May leak" is a label, not a shrug: `allow` exists, and it is named
	`allow('Allow (may leak)')` in code.
- If a check cannot run, it is `notTested`/`notSupported`
	(`CheckStatus`), never a green tick.
- If a platform has no tunnel, `startTunnel` fails with
	`platform.missing` and the capabilities map says why
	(`PlatformCapabilities.web` is the model).
- Documentation follows the same rule: a doc that overstates a protection
	is treated as a bug (see SECURITY.md, "Reports about documentation
	claiming something the code does not do … are welcome as ordinary
	issues").

## 7. Pull request checklist

- [ ] `cd packages/phantrix_core && dart analyze && dart test` — clean
- [ ] `cd packages/phantrix_platform && flutter analyze` — clean
- [ ] New behaviour has new tests (providers, validators, scorer and the
		state machine are all pure — there is no excuse for an untested
		branch)
- [ ] Any new loggable field is covered by a `Redactor` test
- [ ] No TODOs, stubs or "pretend" implementations in core VPN paths
		(parsers, validators, state machine, bridge)
- [ ] No secrets, keystores, `key.properties` or machine-local paths in
		the diff
- [ ] Tabs, `final` fields, strong types, stable error codes
- [ ] User-visible claims match the code: README / SECURITY / PRIVACY /
		BUILDING / ARCHITECTURE updated in the same PR when a capability
		changes, including *removing* a claim the code can no longer make
- [ ] The PR description says what was tested, on which device/OS, and
		what was **not** tested

Thank you — precision here is what makes a free client worth trusting.
