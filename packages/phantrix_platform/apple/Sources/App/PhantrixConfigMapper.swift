// Maps the validated Dart configuration onto a WireGuardKit
// `TunnelConfiguration`.
//
// This is the Apple counterpart of the Android
// `WgConfigMapper` and the Linux config renderer. It exists
// so that the Dart layer's validation and the engine's
// configuration cannot disagree: there is one mapping, it
// runs the same checks, and it produces the same
// full-tunnel guarantee the other platforms produce.
//
// ## The full-tunnel guarantee
//
// A peer that carries no IPv4 default route gets
// `0.0.0.0/0` added, and likewise `::/0` when IPv6 is
// permitted. This is the second of two layers: the Dart
// layer already applies the same repair in
// `VpnConfiguration.effective`, and that is where the user
// is told about it. Applying it here too means a
// configuration that reached this mapper without passing
// through the Dart repair would still install a full
// tunnel rather than a silently leaky one.

import Foundation

/// Everything the mapper needs from a request, after
/// validation, in one place.
struct PhantrixAppleRequest {
	let privateKey: String
	let addresses: [String]
	let dns: [String]
	let mtu: UInt16?
	let peers: [PhantrixApplePeer]
	let ipv6Policy: Ipv6Policy
	let allowLan: Bool
}

struct PhantrixApplePeer {
	let publicKey: String
	let preSharedKey: String?
	let endpoint: String?
	let allowedIps: [String]
	let persistentKeepalive: UInt16?
}

enum Ipv6Policy: String {
	case block
	case preferTunnel = "prefer_tunnel"
	case allow
}

/// The result of mapping a request: either a configuration
/// the engine accepts, or a user-safe reason it does not.
enum ConfigMappingResult {
	case mapped(TunnelConfiguration)
	case rejected(code: String, message: String)
}

enum PhantrixConfigMapper {

	/// Parses the request the plugin receives and maps it.
	///
	/// The request is a map whose `configJson` entry is the
	/// serialised configuration, exactly as the Android and
	/// Windows backends receive it. Going through the same
	/// shape means a change to the wire format is caught on
	/// every platform at once.
	static func map(_ payload: [String: Any]) -> ConfigMappingResult {
		guard let configJson = payload["configJson"] as? String,
		      let data = configJson.data(using: .utf8),
		      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
			return .rejected(
				code: "config.unreadable",
				message: "The tunnel configuration was not in a form this platform can read.",
			)
		}

		guard let wireguard = json["wireguard"] as? [String: Any] else {
			// OpenVPN is reported as unsupported rather than
			// silently ignored, because this backend cannot
			// speak it and pretending otherwise would connect
			// the user to nothing.
			return .rejected(
				code: "config.unsupported_protocol",
				message: "This build can only start a WireGuard tunnel on Apple platforms, and the selected server offers OpenVPN.",
			)
		}

		let request = parseRequest(wireguard, payload)
		return buildConfiguration(from: request)
	}

	// MARK: - Parsing

	private static func parseRequest(_ wireguard: [String: Any], _ root: [String: Any]) -> PhantrixAppleRequest {
		let policy: Ipv6Policy
		switch (root["ipv6"] as? String) {
		case "block": policy = .block
		case "allow": policy = .allow
		default: policy = .preferTunnel
		}

		var peers: [PhantrixApplePeer] = []
		if let peerList = wireguard["peers"] as? [[String: Any]] {
			for entry in peerList {
				let allowedIps = stringList(entry["allowedIps"])
				// The endpoint arrives as "host:port" and is
				// kept whole, because WireGuardKit's Endpoint
				// parser validates it and this mapper does not
				// need to understand its grammar.
				peers.append(PhantrixApplePeer(
					publicKey: string(entry["publicKey"]),
					preSharedKey: optionalString(entry["presharedKey"]),
					endpoint: optionalString(entry["endpoint"]),
					allowedIps: allowedIps,
					persistentKeepalive: optionalUInt16(entry["persistentKeepalive"])
				))
			}
		}

		return PhantrixAppleRequest(
			privateKey: string(wireguard["privateKey"]),
			addresses: stringList(wireguard["addresses"]),
			dns: stringList(wireguard["dns"]),
			mtu: optionalUInt16(wireguard["mtu"]),
			peers: peers,
			ipv6Policy: policy,
			allowLan: (root["allowLan"] as? Bool) ?? false
		)
	}

	private static func string(_ value: Any?) -> String {
		return value as? String ?? ""
	}

	private static func optionalString(_ value: Any?) -> String? {
		guard let value = value as? String, !value.isEmpty else { return nil }
		return value
	}

	private static func stringList(_ value: Any?) -> [String] {
		guard let list = value as? [Any] else { return [] }
		return list.compactMap { $0 as? String }
	}

	private static func optionalUInt16(_ value: Any?) -> UInt16? {
		guard let number = value as? NSNumber else { return nil }
		let int = number.intValue
		guard int > 0, int <= UInt16.max else { return nil }
		return UInt16(int)
	}

	// MARK: - Building

	private static func buildConfiguration(from request: PhantrixAppleRequest) -> ConfigMappingResult {
		guard let privateKey = PrivateKey(base64Key: request.privateKey) else {
			return .rejected(
				code: "wg.private_key_invalid",
				message: "The tunnel's private key is not a valid WireGuard key.",
			)
		}

		// IPv6 policy is applied here, not in the engine,
		// because the engine installs whatever routes the
		// configuration carries: an IPv6 address or `::/0`
		// left in place becomes an IPv6 route, which is
		// exactly what "block IPv6" exists to prevent.
		let carryIpv6: Bool
		switch request.ipv6Policy {
		case .block:
			carryIpv6 = false
		case .preferTunnel, .allow:
			carryIpv6 = request.addresses.contains { $0.contains(":") }
				|| request.peers.contains { $0.allowedIps.contains { $0.contains(":") } }
		}

		var addresses = request.addresses
		if !carryIpv6 {
			addresses = addresses.filter { !$0.contains(":") }
		}
		guard !addresses.isEmpty else {
			return .rejected(
				code: "wg.address_missing",
				message: "The tunnel configuration has no IPv4 address for this device.",
			)
		}

		var interface = InterfaceConfiguration(privateKey: privateKey)
		interface.addresses = addresses.compactMap { IPAddressRange(from: $0) }
		interface.dns = request.dns.compactMap { DNSServer(from: $0) }
		interface.mtu = request.mtu

		guard !request.peers.isEmpty else {
			return .rejected(
				code: "wg.peer.missing",
				message: "The tunnel needs at least one peer, and none was supplied.",
			)
		}

		var peers: [PeerConfiguration] = []
		for (index, peer) in request.peers.enumerated() {
			guard let publicKey = PublicKey(base64Key: peer.publicKey) else {
				return .rejected(
					code: "wg.peer.public_key_invalid",
					message: "Peer \(index + 1) of the tunnel has a server public key that is not valid.",
				)
			}
			var mapped = PeerConfiguration(publicKey: publicKey)
			if let preSharedKey = peer.preSharedKey, let key = PreSharedKey(base64Key: preSharedKey) {
				mapped.preSharedKey = key
			}
			if let endpoint = peer.endpoint, let parsed = Endpoint(from: endpoint) {
				mapped.endpoint = parsed
			}

			// AllowedIPs become the operating system's routes,
			// so the IPv6 policy and the full-tunnel guarantee
			// both bite here.
			var allowedIps = peer.allowedIps
			if !carryIpv6 {
				allowedIps = allowedIps.filter { !$0.contains(":") }
			}
			if !allowedIps.contains("0.0.0.0/0") {
				allowedIps.insert("0.0.0.0/0", at: 0)
			}
			if carryIpv6 && !allowedIps.contains("::/0") {
				allowedIps.append("::/0")
			}
			guard !allowedIps.isEmpty else {
				return .rejected(
					code: "wg.peer.allowed_ips_missing",
					message: "Peer \(index + 1) of the tunnel has no usable IP ranges, so it would receive no traffic and everything would bypass the tunnel.",
				)
			}
			mapped.allowedIPs = allowedIps.compactMap { IPAddressRange(from: $0) }
			mapped.persistentKeepAlive = peer.persistentKeepalive
			peers.append(mapped)
		}

		return .mapped(TunnelConfiguration(name: "Phantrix", interface: interface, peers: peers))
	}
}
