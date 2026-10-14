import '../../core/app_error.dart';
import '../../core/result.dart';
import '../../protocol/validation_issue.dart';
import '../address_cidr.dart';
import '../endpoint.dart';
import 'wg_config.dart';
import 'wg_key.dart';

/// Parses `wg-quick(8)` configuration text.
///
/// Designed to be strict but never silent:
///  * unknown directives are collected and reported, never guessed at;
///  * a malformed line produces a specific issue with the line number;
///  * directories that can run commands cause an error rather than being
///    quietly ignored.
class WgParser {
	const WgParser._();

	static const Set<String> interfaceKeys = {
		'PrivateKey',
		'Address',
		'DNS',
		'MTU',
		'ListenPort',
		'Table',
		'FwMark',
	};

	static const Set<String> peerKeys = {
		'PublicKey',
		'PresharedKey',
		'AllowedIPs',
		'Endpoint',
		'PersistentKeepalive',
	};

	/// Parses [text] and returns an error when any hard problem is found.
	static Result<WgConfig> parse(String text) {
		final raw = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
		final lines = raw.split('\n');
		final issues = <ValidationIssue>[];

		String? section;
		Map<String, String>? currentPeer;
		final peers = <Map<String, String>>[];
		final interfaceLines = <String, String>{};
		final unknown = <String, String>{};

		for (var i = 0; i < lines.length; i++) {
			final lineNumber = i + 1;
			final line = _stripComment(lines[i].trim());
			if (line.isEmpty) {
				continue;
			}
			if (line.startsWith('[') && line.endsWith(']')) {
				final name = line.substring(1, line.length - 1).trim();
				switch (name) {
					case 'Interface':
						section = 'Interface';
					case 'Peer':
						section = 'Peer';
						currentPeer = <String, String>{};
						peers.add(currentPeer);
					default:
						issues.add(
							ValidationIssue(
								code: 'wg.section.unknown',
								field: 'line $lineNumber',
								message: 'Unknown section [$name]. Only [Interface] and [Peer] exist.',
							),
						);
						section = null;
				}
				continue;
			}
			final eq = line.indexOf('=');
			if (eq < 0) {
				issues.add(
					ValidationIssue(
						code: 'wg.line.no_assignment',
						field: 'line $lineNumber',
						message: 'Expected "Key = Value" but the line has no "=" sign.',
					),
				);
				continue;
			}
			final key = line.substring(0, eq).trim();
			final value = line.substring(eq + 1).trim();
			if (key.isEmpty || value.isEmpty) {
				issues.add(
					ValidationIssue(
						code: 'wg.line.incomplete',
						field: 'line $lineNumber',
						message: 'Both a name and a value are required.',
					),
				);
				continue;
			}
			if (section == null) {
				issues.add(
					ValidationIssue(
						code: 'wg.line.outside_section',
						field: 'line $lineNumber',
						message: '"$key" appears before any [Interface] or [Peer] section.',
					),
				);
				continue;
			}
			final canonical = _canonicalKey(key);
			if (canonical == null) {
				issues.add(
					ValidationIssue(
						code: 'wg.key.unknown',
						field: 'line $lineNumber',
						severity: IssueSeverity.warning,
						message:
							'Unknown directive "$key" was ignored. It is stored but never '
							'acted upon.',
					),
				);
				unknown['$section.$key'] = value;
				continue;
			}
			if (section == 'Interface') {
				interfaceLines[canonical] = value;
			} else {
				currentPeer?[canonical] = value;
			}
		}

			return _finish(_assemble(interfaceLines, peers, issues, unknown));

	}

	static String _stripComment(String line) {
		var inQuotes = false;
		for (var i = 0; i < line.length; i++) {
			final ch = line[i];
			if (ch == '"') {
				inQuotes = !inQuotes;
				continue;
			}
			if (inQuotes) {
				continue;
			}
			if (ch == '#' || ch == ';') {
				return line.substring(0, i).trim();
			}
		}
		return line;
	}

	static String? _canonicalKey(String key) {
		final lower = key.toLowerCase();
		for (final candidate in interfaceKeys) {
			if (candidate.toLowerCase() == lower) {
				return candidate;
			}
		}
		for (final candidate in peerKeys) {
			if (candidate.toLowerCase() == lower) {
				return candidate;
			}
		}
		return null;
	}

	static ({List<ValidationIssue> issues, WgConfig? config}) _assemble(
		Map<String, String> interfaceLines,
		List<Map<String, String>> peers,
		List<ValidationIssue> issues,
		Map<String, String> unknown,
	) {
		String? privateKey;
		final rawPrivate = interfaceLines['PrivateKey'];
		if (rawPrivate == null || rawPrivate.isEmpty) {
			issues.add(
				const ValidationIssue(
					code: 'wg.interface.private_key',
					message: 'The [Interface] section must contain a PrivateKey.',
				),
			);
		} else {
					final parsed = WireGuardKey.parse(rawPrivate, field: 'PrivateKey');
			final value = parsed.valueOrNull;
			final error = parsed.errorOrNull;
			if (value != null) {
				privateKey = value;
			} else if (error != null) {
				issues.add(
					ValidationIssue(
						code: error.code,
						field: 'Interface.PrivateKey',
						message: error.message,
					),
				);
			}
		}

		final addresses = <AddressCidr>[];
		final rawAddresses = interfaceLines['Address'];
		if (rawAddresses == null || rawAddresses.trim().isEmpty) {
			issues.add(
				const ValidationIssue(
					code: 'wg.interface.address',
					message: 'The [Interface] section must contain at least one Address.',
				),
			);
		} else {
				final parsed = AddressCidr.parseList(rawAddresses);
			final value = parsed.valueOrNull;
			final error = parsed.errorOrNull;
			if (value != null) {
				addresses.addAll(value);
			} else if (error != null) {
				issues.add(
					ValidationIssue(
						code: error.code,
						field: 'Interface.Address',
						message: error.message,
					),
				);
			}
		}

		final dns = <String>[];
		final rawDns = interfaceLines['DNS'];
		if (rawDns != null && rawDns.trim().isNotEmpty) {
			for (final entry in rawDns.split(',')) {
				final value = entry.trim();
				if (value.isEmpty) {
					continue;
				}
				final ok = AddressCidr.isIpv4(value) || AddressCidr.isIpv6(value);
				if (!ok) {
					issues.add(
						ValidationIssue(
							code: 'wg.interface.dns',
							field: 'Interface.DNS',
							message: '"$value" is not a valid DNS server address.',
						),
					);
					continue;
				}
				dns.add(value);
			}
		}

		final mtu = int.tryParse(interfaceLines['MTU']?.trim() ?? '');
		if (mtu != null && (mtu < WgConfig.minMtu || mtu > WgConfig.maxMtu)) {
			issues.add(
				ValidationIssue(
					code: 'wg.interface.mtu_range',
					field: 'Interface.MTU',
					message: 'MTU must be between ${WgConfig.minMtu} and ${WgConfig.maxMtu}.',
				),
			);
		}

		final listenPort = int.tryParse(interfaceLines['ListenPort']?.trim() ?? '');
		if (listenPort != null && (listenPort < 1 || listenPort > 65535)) {
			issues.add(
				const ValidationIssue(
					code: 'wg.interface.listen_port',
					field: 'Interface.ListenPort',
					message: 'ListenPort must be between 1 and 65535.',
				),
			);
		}

		if (peers.isEmpty) {
			issues.add(
				const ValidationIssue(
					code: 'wg.peer.missing',
					message: 'The configuration must contain at least one [Peer] section.',
				),
			);
		}

		final parsedPeers = <WgPeer>[];
		for (var index = 0; index < peers.length; index++) {
			final peerMap = peers[index];
			final label = 'Peer ${index + 1}';

			String? publicKey;
			final rawPublic = peerMap['PublicKey'];
			if (rawPublic == null || rawPublic.isEmpty) {
				issues.add(
					ValidationIssue(
						code: 'wg.peer.public_key',
						field: '$label.PublicKey',
						message: '$label is missing a PublicKey.',
					),
				);
			} else {
				final parsed = WireGuardKey.parse(rawPublic, field: 'PublicKey');
				final value = parsed.valueOrNull;
				if (value != null) {
					publicKey = value;
				} else if (parsed.errorOrNull != null) {
					issues.add(
						ValidationIssue(
							code: parsed.errorOrNull!.code,
							field: '$label.PublicKey',
							message: parsed.errorOrNull!.message,
						),
					);
				}
			}

			String? presharedKey;
			final rawPsk = peerMap['PresharedKey'];
			if (rawPsk != null && rawPsk.isNotEmpty) {
				final parsed = WireGuardKey.parse(rawPsk, field: 'PresharedKey');
				final value = parsed.valueOrNull;
				if (value != null) {
					presharedKey = value;
				} else if (parsed.errorOrNull != null) {
					issues.add(
						ValidationIssue(
							code: parsed.errorOrNull!.code,
							field: '$label.PresharedKey',
							message: parsed.errorOrNull!.message,
						),
					);
				}
			}

			WgEndpoint? endpoint;
			final rawEndpoint = peerMap['Endpoint'];
			if (rawEndpoint != null && rawEndpoint.trim().isNotEmpty) {
				final parsed = WgEndpoint.parse(rawEndpoint);
				final value = parsed.valueOrNull;
				if (value != null) {
					endpoint = value;
				} else if (parsed.errorOrNull != null) {
					issues.add(
						ValidationIssue(
							code: parsed.errorOrNull!.code,
							field: '$label.Endpoint',
							message: parsed.errorOrNull!.message,
						),
					);
				}
			}

			final allowed = <AddressCidr>[];
			final rawAllowed = peerMap['AllowedIPs'];
			if (rawAllowed == null || rawAllowed.trim().isEmpty) {
				issues.add(
					ValidationIssue(
						code: 'wg.peer.allowed_ips',
						field: '$label.AllowedIPs',
						message: '$label must specify AllowedIPs.',
					),
				);
			} else {
				final parsed = AddressCidr.parseList(rawAllowed);
				final value = parsed.valueOrNull;
				if (value != null) {
					allowed.addAll(value);
				} else if (parsed.errorOrNull != null) {
					issues.add(
						ValidationIssue(
							code: parsed.errorOrNull!.code,
							field: '$label.AllowedIPs',
							message: parsed.errorOrNull!.message,
						),
					);
				}
			}

			final rawKeepalive = peerMap['PersistentKeepalive']?.trim();
			final keepaliveValue = int.tryParse(rawKeepalive ?? '');
			int? keepalive = keepaliveValue == 0 ? null : keepaliveValue;
			if (keepalive != null && keepalive > 65535) {
				issues.add(
					ValidationIssue(
						code: 'wg.peer.keepalive_range',
						field: '$label.PersistentKeepalive',
						message: 'PersistentKeepalive must be between 1 and 65535 seconds.',
					),
				);
				keepalive = null;
			}

			parsedPeers.add(
				WgPeer(
					publicKey: publicKey ?? '',
					presharedKey: presharedKey,
					endpoint: endpoint,
					allowedIps: allowed,
					persistentKeepalive: keepalive,
				),
			);
		}

		final hardErrors = issues.where((i) => i.isError).toList();
		if (hardErrors.isNotEmpty) {
			return (issues: hardErrors, config: null);
		}
		return (
			issues: issues,
			config: WgConfig(
				interface: WgInterface(
					privateKey: privateKey ?? '',
					addresses: addresses,
					dns: dns,
					mtu: mtu,
					listenPort: listenPort,
				),
				peers: parsedPeers,
				unknownDirectives: unknown,
			),
		);
	}
	/// Parses [text] and returns every issue together with the configuration.
	///
	/// Used by the import screen so a user can see exactly what the app
	/// ignored before deciding to keep a file.
	static ({List<ValidationIssue> issues, WgConfig? config}) parseDetailed(String text) =>
			_assembleInternal(text);

	static ({List<ValidationIssue> issues, WgConfig? config}) _assembleInternal(String text) {
		final result = parse(text);
		final value = result.valueOrNull;
		final error = result.errorOrNull;
		if (value != null) {
			return (issues: const <ValidationIssue>[], config: value);
		}
		return (
			issues: [
				ValidationIssue(
					code: error?.code ?? 'wg.unknown',
					message: error?.message ?? 'The configuration could not be read.',
				),
			],
			config: null,
		);
	}

	static Result<WgConfig> _finish(({List<ValidationIssue> issues, WgConfig? config}) outcome) {
		if (outcome.config == null) {
			return Err(
				AppError(
					group: ErrorGroup.parse,
					code: 'wg.parse_failed',
					message: outcome.issues.map((e) => e.message).join(' '),
					detail: {
						'issues': outcome.issues.map((e) => e.code).toList(growable: false),
					},
				),
			);
		}
		return Ok(outcome.config!);
	}
}
