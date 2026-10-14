import '../../core/app_error.dart';
import '../../core/result.dart';
import '../../protocol/validation_issue.dart';
import 'ovpn_config.dart';

/// The outcome of validating an OpenVPN configuration.
class OvpnVerdict {
	const OvpnVerdict({
		required this.config,
		required this.issues,
		required this.repairs,
	});

	final OvpnConfig config;
	final List<ValidationIssue> issues;

	/// The changes the engine will apply to the config before starting the
	/// tunnel. Surfaced to the user so nothing is silently modified.
	final List<String> repairs;

	bool get isSafe => issues.every((i) => !i.isError);
}
/// Security policy for OpenVPN configurations.
///
/// The two failure modes we must never ship are:
///  1. running attacker-supplied commands (`up`/`down`/`plugin`/`config`);
///  2. disabling authentication because a handshake would otherwise fail.
///
/// Everything here is enforced, not advisory. Items that are merely risky are
/// reported as [IssueSeverity.warning] and shown in the import UI.
class OvpnValidator {
	const OvpnValidator._();

	/// Directives that cause OpenVPN to execute a program. Not supported.
	static const Set<String> executionDirectives = {
		'up',
		'down',
		'route-up',
		'tls-verify',
		'ipchange',
		'client-connect',
		'client-disconnect',
		'learn-address',
		'auth-user-pass-verify',
		'plugin',
		'config',
		'cd',
		'chroot',
		'daemon',
		'ifconfig-noexec',
		'route-noexec',
		'management',
		'management-client',
		'status',
		'log',
		'log-append',
		'machine-id',
	};

	/// Ciphers that provide no confidentiality.
	static const Set<String> brokenCiphers = {
		'none',
		'null-cipher',
		'null',
		'des',
		'des-cbc',
		'des-ede-cbc',
		'des-ede3-cbc',
		'rc2-40-cbc',
		'rc2-64-cbc',
		'bf-cbc',
		'rc2-cbc',
		'cast5-cbc',
		'desx-cbc',
		'rc4',
	};

	/// Message digests that are not collision resistant.
	static const Set<String> brokenAuth = {
		'none',
		'md4',
		'md5',
		'rmd160',
	};

	/// File-based trust material. Rejected unless an inline block is absent
	/// and the file lives inside the app's own import directory.
	static const Set<String> fileDirectives = {
		'ca',
		'cert',
		'key',
		'dh',
		'pkcs12',
		'tls-auth',
		'tls-crypt',
		'tls-crypt-v2',
		'extra-certs',
		'crl-verify',
		'http-proxy-user-pass',
	};

	static Result<OvpnVerdict> validate(OvpnConfig config) {
		final issues = <ValidationIssue>[];
		final repairs = <String>[];

		// 1. Command execution.
		for (final directive in config.unknownDirectives.entries) {
			final key = directive.key.toLowerCase();
			if (executionDirectives.contains(key)) {
				return Err(
					AppError(
						group: ErrorGroup.configuration,
						code: 'ovpn.forbidden_directive',
						message:
							'The configuration contains "$key". Directives that run programs '
							'or read arbitrary files are not supported, so this '
							'configuration was rejected.',
						detail: {'directive': key},
					),
				);
			}
		}

		final scriptSecurity = int.tryParse(
			config.unknownDirectives['script-security'] ?? '1',
		);
		if (scriptSecurity != null && scriptSecurity >= 2) {
			return Err(
				AppError(
					group: ErrorGroup.configuration,
					code: 'ovpn.script_security',
					message:
						'script-security 2 lets a configuration run arbitrary programs. '
						'This configuration was rejected.',
					detail: {'directive': 'script-security'},
				),
			);
		}

		// 2. Critical material: inline only.
		for (final directive in fileDirectives) {
			final value = config.unknownDirectives[directive];
			if (value == null || value.isEmpty) {
				continue;
			}
			if (config.inlineBlocks.containsKey(directive)) {
				continue;
			}
			return Err(
				AppError(
					group: ErrorGroup.configuration,
					code: 'ovpn.external_file_forbidden',
					message:
						'The configuration references an external "$directive" file. '
						'Phantrix only accepts trust material embedded in the '
						'configuration itself, so this file was rejected.',
					detail: {'directive': directive},
				),
			);
		}
		final askPass = config.unknownDirectives['askpass'];
		if (askPass != null && askPass.isNotEmpty) {
			return Err(
				AppError(
					group: ErrorGroup.configuration,
					code: 'ovpn.askpass_forbidden',
					message:
						'askpass reads credentials from a file on disk. Phantrix asks for '
						'credentials at connection time and never reads credential files '
						'supplied by a configuration, so this configuration was rejected.',
					detail: {'directive': 'askpass'},
				),
			);
		}

		// 3. Trust: we must be able to verify the server.
		final ca = config.inlineBlocks['ca'];
		final caFileEmpty = config.caFile?.trim().isEmpty ?? true;
		final caPathEmpty = config.caPath?.trim().isEmpty ?? true;
		if (ca == null && caFileEmpty && caPathEmpty) {
			return Err(
				AppError(
					group: ErrorGroup.configuration,
					code: 'ovpn.no_ca',
					message:
						'The configuration contains no CA certificate. Without it the '
						'server cannot be authenticated, so the connection was refused.',
					detail: const {'missing': 'ca'},
				),
			);
		}

		// 4. Cipher and MAC policy.
		final cipher = config.cipher?.toLowerCase();
		final declaredCiphers = [if (cipher != null) cipher, ...config.dataCiphers.map((c) => c.toLowerCase())];
		if (declaredCiphers.isNotEmpty) {
			for (final candidate in declaredCiphers) {
				if (brokenCiphers.contains(candidate)) {
					return Err(
						AppError(
							group: ErrorGroup.configuration,
							code: 'ovpn.broken_cipher',
							message:
								'The configuration requests the cipher "$candidate", which does '
								'not provide confidentiality. It was rejected.',
							detail: {'cipher': candidate},
						),
					);
				}
			}
		}
		final auth = config.auth?.toLowerCase();
		if (auth != null && brokenAuth.contains(auth)) {
			return Err(
				AppError(
					group: ErrorGroup.configuration,
					code: 'ovpn.broken_auth',
					message:
						'The configuration requests the message digest "$auth", which is not '
						'collision resistant. It was rejected.',
					detail: {'auth': auth},
				),
			);
		}

		// 5. Remotes.
		if (config.remotes.isEmpty) {
			return Err(
				AppError(
					group: ErrorGroup.configuration,
					code: 'ovpn.no_remote',
					message: 'The configuration contains no "remote" server address.',
				),
			);
		}
		for (final remote in config.remotes) {
			if (!_validHost(remote.host)) {
				return Err(
					AppError(
						group: ErrorGroup.configuration,
						code: 'ovpn.remote_host',
						message: '"${remote.host}" is not a valid server hostname or address.',
						detail: const {'remote_host_form': 'invalid'},
					),
				);
			}
			if (remote.port < 1 || remote.port > 65535) {
				return Err(
					AppError(
						group: ErrorGroup.configuration,
						code: 'ovpn.remote_port',
						message: 'The remote port ${remote.port} is out of range.',
						detail: const {'remote_port': 'range'},
					),
				);
			}
		}

		final dev = config.dev?.toLowerCase();
		if (dev != null && dev.startsWith('tap')) {
			return Err(
				AppError(
					group: ErrorGroup.configuration,
					code: 'ovpn.tap_unsupported',
					message:
						'This configuration uses a "tap" (layer 2) device. Phantrix '
						'implements "tun" (layer 3) routing, so it was rejected.',
					detail: const {'dev': 'tap'},
				),
			);
		}

		// 6. Routing: a config that neither pulls nor redirects will leak.
		final needsPullRepair = (config.pull ?? false) == false;
		if (needsPullRepair) {
			repairs.add(
				'Enable "pull" so the server can supply its routes instead of '
				'using the routes hard-coded in this file.',
			);
			issues.add(
				const ValidationIssue(
					code: 'ovpn.pull.missing',
					severity: IssueSeverity.warning,
					message:
						'The configuration does not use "pull". Without it, the routes '
						'inside the file are used as-is and traffic can leave outside '
						'the tunnel.',
				),
			);
		}
		if (needsPullRepair && config.routeNopull) {
			return Err(
				AppError(
					group: ErrorGroup.configuration,
					code: 'ovpn.route_nopull',
					message:
						'This configuration blocks the server from pushing routes '
						'("route-nopull") while also not pulling them, which leaves your '
						'traffic outside the tunnel. It was rejected.',
					detail: const {'route_nopull': true},
				),
			);
		}
		if (config.routeNopull) {
			repairs.add('Remove "route-nopull" so the server route is used.');
			issues.add(
				const ValidationIssue(
					code: 'ovpn.route_nopull',
					severity: IssueSeverity.warning,
					message:
						'"route-nopull" ignores the servers routing push and is the most '
						'common cause of VPN leaks.',
				),
			);
		}
		if ((config.redirectGateway ?? false) == false) {
			repairs.add('Enable "redirect-gateway def1 bypass-dhcp" for a full tunnel.');
			issues.add(
				const ValidationIssue(
					code: 'ovpn.redirect_gateway.missing',
					severity: IssueSeverity.warning,
					message:
						'The configuration does not redirect the default gateway. Phantrix '
						'will force one.',
				),
			);
		}

		// 7. DNS.
		if (config.dhcpOptionDns.isEmpty) {
			repairs.add('Set the VPN-provided DNS server while connected.');
			issues.add(
				const ValidationIssue(
					code: 'ovpn.dns.missing',
					severity: IssueSeverity.info,
					message: 'No DNS servers in the configuration; the VPN DNS will be used.',
				),
			);
		}

		// 8. Client certificate sanity.
		final hasCert = config.inlineBlocks.containsKey('cert');
		final hasKey = config.inlineBlocks.containsKey('key');
		if (hasCert != hasKey) {
			return Err(
				AppError(
					group: ErrorGroup.configuration,
					code: 'ovpn.incomplete_client_identity',
					message:
						'The configuration has a client ${hasCert ? 'certificate' : 'private key'} '
						'but not the matching ${hasCert ? 'private key' : 'certificate'}.',
					detail: const {'inline_blocks': 'mismatched'},
				),
			);
		}
		if (hasKey && !_looksLikePrivateKey(config.inlineBlocks['key']!.body)) {
			return Err(
				AppError(
					group: ErrorGroup.configuration,
					code: 'ovpn.private_key_unreadable',
					message: 'The inline private key is not a recognised PEM private key.',
					detail: const {'pem': 'unrecognised'},
				),
			);
		}

		// 9. Auth requirement is informational, never an error.
		if (config.authUserPass) {
			issues.add(
				const ValidationIssue(
					code: 'ovpn.credentials_required',
					severity: IssueSeverity.info,
					message: 'This server asks for a username and password.',
				),
			);
		}

		final failures = issues.where((i) => i.isError).toList();
		if (failures.isNotEmpty) {
			return Err(
				AppError(
					group: ErrorGroup.validation,
					code: 'ovpn.invalid',
					message: failures.map((f) => f.message).join(' '),
					detail: {'issues': failures.map((f) => f.code).toList(growable: false)},
				),
			);
		}
		return Ok(OvpnVerdict(config: config, issues: issues, repairs: repairs));
	}

	static bool _validHost(String host) {
		if (host.isEmpty || host.length > 253) {
			return false;
		}
		if (RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(host)) {
			// Split rather than index capture groups. The pattern above has a
			// single group, so asking for groups 1..4 threw a RangeError on
			// every IPv4 remote — which is most of them.
			return host
					.split('.')
					.every((octet) => (int.tryParse(octet) ?? 256) <= 255);
		}
		if (host.contains(':') && RegExp(r'^[0-9A-Fa-f:]+$').hasMatch(host)) {
			return true;
		}
		return _validHostName(host);
	}

	/// Whether [host] is a well-formed domain name.
	///
	/// Each label must start and end with an alphanumeric (or an underscore,
	/// which occurs in real-world records) and may contain hyphens only in
	/// the middle. This is RFC 1123 hostname grammar, and it is checked label
	/// by label rather than with one whole-string pattern because a single
	/// pattern that permits interior hyphens almost always permits a leading
	/// one too — which is exactly what the previous `[A-Za-z0-9_-]` class
	/// did.
	static bool _validHostName(String host) {
		final labels = host.split('.');
		// A VPN remote is a public name, so a bare label with no dot is not
		// accepted. This is stricter than DNS permits and deliberately so:
		// a single-label remote is far more likely to be a mistake than to be
		// a server, and a mistake here is a connection that silently goes
		// nowhere.
		if (labels.length < 2) {
			return false;
		}
		for (final label in labels) {
			if (label.isEmpty || label.length > 63) {
				return false;
			}
			if (!RegExp(r'^[A-Za-z0-9_]([A-Za-z0-9_-]{0,61}[A-Za-z0-9_])?$')
					.hasMatch(label)) {
				return false;
			}
		}
		// The last label must contain a letter. A purely numeric final label
		// ("192.0.2") is not a top-level domain, and a name that is only
		// digits and dots is an incomplete address rather than a hostname.
		// This is what stops a truncated IPv4 address from being accepted as
		// a server name it can never be.
		return RegExp(r'[A-Za-z]').hasMatch(labels.last);
	}

	static bool _looksLikePrivateKey(String body) {
		final trimmed = body.trim();
		return trimmed.contains('PRIVATE KEY-----') ||
				trimmed.contains('-----BEGIN EC PRIVATE KEY-----') ||
				trimmed.contains('-----BEGIN PRIVATE KEY-----');
	}
}
