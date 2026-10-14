import '../logging/fingerprint.dart';
import 'openvpn/ovpn_config.dart';
import 'openvpn/ovpn_validator.dart';
import 'protocol_kind.dart';
import 'validation_issue.dart';
import 'wireguard/wg_config.dart';
import 'wireguard/wg_validator.dart';

/// A configuration that has passed parsing *and* security validation.
///
/// Construction only happens through [VpnConfiguration.wireGuard] and
/// [VpnConfiguration.openVpn], so there is no way to hold an unvalidated
/// configuration in a type that looks validated.
class VpnConfiguration {
	const VpnConfiguration._({
		required this.kind,
		required this.wireGuard,
		required this.openVpn,
		required this.repairs,
		required this.warnings,
		this.fingerprint,
	});

	factory VpnConfiguration.wireGuard(WgVerdict verdict) {
		final config = verdict.config;
		return VpnConfiguration._(
			kind: ProtocolKind.wireGuard,
			wireGuard: config,
			openVpn: null,
			repairs: verdict.routeRepair
					? const [
							'Add the default route (0.0.0.0/0) so traffic cannot bypass the tunnel.',
						]
					: const [],
			warnings: verdict.issues,
			fingerprint: _wgFingerprint(config),
		);
	}

	factory VpnConfiguration.openVpn(OvpnVerdict verdict) {
		return VpnConfiguration._(
			kind: ProtocolKind.openVpn,
			wireGuard: null,
			openVpn: verdict.config,
			repairs: verdict.repairs,
			warnings: verdict.issues,
			fingerprint: _ovpnFingerprint(verdict.config),
		);
	}

	final ProtocolKind kind;
	final WgConfig? wireGuard;
	final OvpnConfig? openVpn;

	/// Human-readable description of what the engine will change before
	/// starting the tunnel. Never empty without the user being told.
	final List<String> repairs;

	/// Non-fatal findings from validation, shown before the user imports.
	final List<ValidationIssue> warnings;

	final String? fingerprint;

	/// The address of the tunnel endpoint, if the protocol has one.
	String? get endpointHost => switch (kind) {
		ProtocolKind.wireGuard => wireGuard?.primaryEndpoint?.host,
		ProtocolKind.openVpn => openVpn?.remotes.firstOrNull?.host,
	};

	int? get endpointPort => switch (kind) {
		ProtocolKind.wireGuard => wireGuard?.primaryEndpoint?.port,
		ProtocolKind.openVpn => openVpn?.remotes.firstOrNull?.port,
	};

	List<String> get dnsServers => switch (kind) {
		ProtocolKind.wireGuard => wireGuard?.interface.dns ?? const [],
		ProtocolKind.openVpn => openVpn?.dhcpOptionDns ?? const [],
	};

	/// Whether this configuration can carry IPv6 through the tunnel. When
	/// false, the engine must block IPv6 rather than leak it.
	bool get supportsIpv6 => switch (kind) {
		ProtocolKind.wireGuard => wireGuard?.supportsIpv6Route ?? false,
		// An OpenVPN server pushes an IPv6 route when it has one; we cannot
		// know from the config alone, so the engine applies the user's policy.
		ProtocolKind.openVpn => false,
	};

	/// Whether every peer carries a default route, i.e. the tunnel is a full
	/// tunnel rather than a split tunnel.
	///
	/// True for OpenVPN configurations, where the server pushes its own routes
	/// and there is no per-peer list to inspect.
	bool get isFullTunnel => switch (kind) {
		ProtocolKind.wireGuard => wireGuard?.isFullTunnel ?? false,
		ProtocolKind.openVpn => true,
	};

	/// The configuration that will actually be handed to the engine.
	///
	/// [VpnConfiguration] as produced by the validator describes what the user
	/// *wrote*. This describes what the tunnel will *do*, which is not always
	/// the same thing. The one difference today is the full-tunnel repair:
	/// a WireGuard configuration whose peers carry no default route would
	/// route only the listed prefixes through the tunnel and silently send
	/// everything else out of the clear physical interface. The validator
	/// flags that in [repairs], but a flag is not a fix — this is where the
	/// fix is applied, in pure Dart, so it is unit-testable and cannot be
	/// forgotten on the native side.
	///
	/// Returning a new object rather than mutating keeps the validated input
	/// intact for diagnostics and for the "what did you give me" question.
	VpnConfiguration get effective {
		final wg = wireGuard;
		if (wg == null || wg.isFullTunnel) {
			return this;
		}
		return VpnConfiguration.wireGuard(
			WgVerdict(
				config: wg.withFullTunnelDefaults(),
				issues: warnings,
				routeRepair: true,
			),
		);
	}
}

String _wgFingerprint(WgConfig config) {
	final peers = config.peers
			.map(
				(p) =>
					'${p.publicKey}|${p.endpoint?.display ?? ''}|${p.allowedIps.map((i) => i.toString()).join(',')}',
			)
			.toList()
		..sort();
	final addresses = [...config.interface.addresses.map((a) => a.toString())]..sort();
	return 'wg:$addresses|${peers.join(';')}';
}

String _ovpnFingerprint(OvpnConfig config) {
	final remotes = config.remotes.map((r) => '${r.host}:${r.port}').join(',');
	final ca = config.inlineBlocks['ca']?.body.trim() ?? '';
	return 'ovpn:$remotes|${_fnv(ca)}';
}

String _fnv(String value) => fingerprintHex(value);
