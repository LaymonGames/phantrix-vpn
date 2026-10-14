import '../address_cidr.dart';
import '../endpoint.dart';

/// A WireGuard interface (the local side of the tunnel).
class WgInterface {
	const WgInterface({
		required this.privateKey,
		required this.addresses,
		this.dns = const [],
		this.mtu,
		this.listenPort,
	});

	final String privateKey;
	final List<AddressCidr> addresses;
	final List<String> dns;
	final int? mtu;
	final int? listenPort;
}

/// A WireGuard peer (the remote side of the tunnel).
class WgPeer {
	const WgPeer({
		required this.publicKey,
		this.presharedKey,
		this.endpoint,
		required this.allowedIps,
		this.persistentKeepalive,
	});

	final String publicKey;
	final String? presharedKey;
	final WgEndpoint? endpoint;
	final List<AddressCidr> allowedIps;
	final int? persistentKeepalive;

	/// True when this peer carries the default route, i.e. the tunnel is a
	/// full tunnel rather than a split tunnel.
	bool get carriesDefaultRoute => allowedIps.any(_isDefault);

	/// True when this peer already carries a default route for both address
	/// families, so nothing needs to be added to make it a full tunnel.
	bool get coversBothFamilies =>
			allowedIps.any((ip) => ip.isV4 && ip.prefixLength == 0) &&
			allowedIps.any((ip) => ip.isV6 && ip.prefixLength == 0);

	static bool _isDefault(AddressCidr ip) =>
			(ip.isV4 && ip.prefixLength == 0) || (ip.isV6 && ip.prefixLength == 0);
}

/// A complete, validated WireGuard configuration.
///
/// This mirrors the `wg-quick(8)` file format. It is produced by the parser,
/// then *only ever mutated through explicit copy helpers* so a validated
/// configuration cannot silently become invalid.
class WgConfig {
	const WgConfig({
		required this.interface,
		required this.peers,
		this.rawText,
		this.unknownDirectives = const {},
	});

	final WgInterface interface;
	final List<WgPeer> peers;

	/// The original text, retained for diagnostics. Never written to disk with
	/// the private key unless the caller explicitly asks for it.
	final String? rawText;

	/// Directives we recognised as syntactically valid but intentionally do
	/// not act on (for example `Table`, `PreUp`, `PostUp`). They are preserved
	/// so a re-export is lossless, but never executed.
	final Map<String, String> unknownDirectives;

	static const int minMtu = 576;
	static const int maxMtu = 1500;
	static const int recommendedMtu = 1280;

	WgConfig copyWith({
		WgInterface? interface,
		List<WgPeer>? peers,
		Map<String, String>? unknownDirectives,
	}) =>
			WgConfig(
				interface: interface ?? this.interface,
				peers: peers ?? this.peers,
				rawText: rawText,
				unknownDirectives: unknownDirectives ?? this.unknownDirectives,
			);

	bool get isFullTunnel => peers.any((p) => p.carriesDefaultRoute);

	/// This configuration with a full-tunnel default route guaranteed.
	///
	/// For each peer that carries no IPv4 default route, `0.0.0.0/0` is
	/// added; likewise `::/0` for IPv6. A peer that already has one is left
	/// alone, so calling this twice is a no-op and never duplicates a route.
	///
	/// Without this, a split-tunnel configuration would route only its listed
	/// prefixes through the tunnel while everything else left the device over
	/// the physical interface — a silent leak that no amount of correct
	/// cryptography would prevent.
	WgConfig withFullTunnelDefaults() {
		if (isFullTunnel && peers.every((p) => p.coversBothFamilies)) {
			return this;
		}
		return copyWith(
			peers: [
				for (final peer in peers) _withMissingDefaults(peer),
			],
		);
	}

	static WgPeer _withMissingDefaults(WgPeer peer) {
		final needsV4 = !peer.allowedIps.any((ip) => ip.isV4 && ip.prefixLength == 0);
		final needsV6 = !peer.allowedIps.any((ip) => ip.isV6 && ip.prefixLength == 0);
		if (!needsV4 && !needsV6) {
			return peer;
		}
		return WgPeer(
			publicKey: peer.publicKey,
			presharedKey: peer.presharedKey,
			endpoint: peer.endpoint,
			persistentKeepalive: peer.persistentKeepalive,
			allowedIps: [
				if (needsV4) const AddressCidr('0.0.0.0', 0),
				if (needsV6) const AddressCidr('::', 0),
				...peer.allowedIps,
			],
		);
	}

	/// Whether any peer carries an IPv6 default route, needed to decide
	/// whether the tunnel can protect IPv6 or must block it.
	bool get supportsIpv6Route => peers.any(
		(peer) => peer.allowedIps.any((ip) => ip.isV6 && ip.prefixLength == 0),
	);

	WgEndpoint? get primaryEndpoint => peers
			.map((p) => p.endpoint)
			.whereType<WgEndpoint>()
			.cast<WgEndpoint?>()
			.firstOrNull;
}
