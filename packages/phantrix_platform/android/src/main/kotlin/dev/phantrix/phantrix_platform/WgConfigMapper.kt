package dev.phantrix.phantrix_platform

import com.wireguard.config.BadConfigException
import com.wireguard.config.Config
import com.wireguard.config.Interface
import com.wireguard.config.Peer
import com.wireguard.crypto.Key

/**
 * Builds an official `com.wireguard.config.Config` from the validated
 * configuration Dart sent.
 *
 * Two things matter here and both are security properties:
 *
 *  1. **No text round-trip.** The Dart side has already parsed, validated and
 *     repaired the configuration. Re-serialising it to `wg-quick` text and
 *     re-parsing would create a second, subtly different interpretation of the
 *     same file, and the two could disagree about what is being tunnelled.
 *     Instead the structured values are mapped field by field onto the
 *     official typed builders, so the object the Go backend receives is a
 *     direct consequence of the validated data.
 *
 *  2. **Validation is repeated, not trusted.** Dart already checked these
 *     values, but this class re-checks everything before handing it to the
 *     official builder. The builder throws `BadConfigException` on malformed
 *     input; converting that into a structured error means a bad
 *     configuration is a clean failure rather than a native crash.
 *
 * The Go backend performs all WireGuard cryptography. Nothing here does, and
 * nothing here may: reimplementing WireGuard is exactly the custom
 * cryptography this project refuses to ship.
 */
internal object WgConfigMapper {

	/**
	 * A mapped configuration plus what the service needs to verify it later.
	 *
	 * [primaryPeerKey] is used to read that peer's statistics — byte counters
	 * and handshake time — which is how the app decides whether "connected"
	 * may honestly be reported.
	 */
	class Mapped(val config: Config, val primaryPeerKey: Key, val endpoint: String?)

	/**
	 * Maps [request] to a WireGuard configuration.
	 *
	 * @throws WgMappingException with a user-safe reason when the payload is
	 *   unusable. The message never contains key material.
	 */
	fun map(request: TunnelRequestKey): Mapped {
		val source = request.wireGuard
			?: throw WgMappingException(
				"configuration.unsupported",
				"This build can only start a WireGuard tunnel, and the selected " +
					"server offers OpenVPN.",
			)

		if (source.peers.isEmpty()) {
			throw WgMappingException(
				"wg.peer.missing",
				"The tunnel needs at least one peer, and none was supplied.",
			)
		}

		// The official engine derives the operating system's routes directly
		// from this Config: it calls addAddress() for each interface address,
		// addDnsServer() for each resolver, and addRoute() for each peer
		// AllowedIPs entry, then establish(). There is no separate routing step
		// this code could perform afterwards, so the user's IPv6 policy has to
		// be applied *here*, by shaping what reaches the engine. Applying it
		// anywhere else would be a policy that is parsed, displayed, and then
		// silently ignored.
		val carryIpv6 = decideIpv6(source, request)
		val peers = source.peers.mapIndexed { index, peer ->
			buildPeer(peer, index, carryIpv6, fullTunnel = true)
		}
		val interfaceBuilder = buildInterface(source, request, carryIpv6)

		val configBuilder = Config.Builder()
		configBuilder.setInterface(interfaceBuilder)
		configBuilder.addPeers(peers)

		return Mapped(
			config = configBuilder.build(),
			primaryPeerKey = peers.first().publicKey,
			endpoint = source.peers.firstOrNull()?.let { "${it.endpointHost}:${it.endpointPort}" },
		)
	}

	/**
	 * Whether IPv6 may be carried through this tunnel.
	 *
	 * The rules, in order:
	 *
	 *  * `BLOCK` — never. IPv6 addresses and `::/0` are stripped, so the
	 *    engine installs no IPv6 route and IPv6 cannot leave by the back door.
	 *  * `PREFER_TUNNEL` — only when the configuration actually carries an
	 *    IPv6 default route. A server with no IPv6 route cannot carry IPv6
	 *    however much the user would like it to, and claiming otherwise would
	 *    mean the UI says "protected" while IPv6 escapes over the physical
	 *    interface.
	 *  * `ALLOW` — only when the user has been told this leaks. The parser logs
	 *    that at request time; here it simply permits what the config supports.
	 */
	private fun decideIpv6(source: WireGuardConfigKey, request: TunnelRequestKey): Boolean {
		val configCarriesIpv6 = source.addresses.any { it.contains(':') } ||
			source.peers.any { peer -> peer.allowedIps.any { it.contains(':') } }
		return when (request.ipv6) {
			Ipv6Policy.BLOCK -> false
			Ipv6Policy.PREFER_TUNNEL -> configCarriesIpv6
			Ipv6Policy.ALLOW -> configCarriesIpv6
		}
	}

	private fun buildInterface(
		source: WireGuardConfigKey,
		request: TunnelRequestKey,
		carryIpv6: Boolean,
	): Interface {
		val builder = Interface.Builder()

		// Private key. Never logged, never echoed into an error message.
		try {
			builder.parsePrivateKey(source.privateKey)
		} catch (error: BadConfigException) {
			throw WgMappingException(
				"wg.private_key_invalid",
				"The tunnel's private key is not a valid WireGuard key.",
			)
		}

		// Addresses. IPv6 addresses are dropped when the policy forbids
		// carrying IPv6: an IPv6 address on the interface makes the engine
		// install IPv6 routes, which is precisely what "block IPv6" is meant to
		// prevent.
		val addresses = if (carryIpv6) {
			source.addresses
		} else {
			source.addresses.filterNot { it.contains(':') }
		}
		if (addresses.isEmpty()) {
			throw WgMappingException(
				"wg.address_missing",
				"The tunnel configuration has no IPv4 address for this device.",
			)
		}
		try {
			builder.parseAddresses(addresses.joinToString(", "))
		} catch (error: BadConfigException) {
			throw WgMappingException(
				"wg.address_invalid",
				"The tunnel's device address is not a valid CIDR range.",
			)
		}

		applyDns(builder, source, request)
		source.mtu?.let { mtu -> applyMtu(builder, mtu) }
		source.listenPort?.let { port -> applyListenPort(builder, port) }
		applyApplicationFilter(builder, request)

		return try {
			builder.build()
		} catch (error: BadConfigException) {
			throw WgMappingException(
				"wg.interface.malformed",
				"The tunnel's local settings are incomplete or inconsistent.",
			)
		}
	}

	/**
	 * Decides which resolvers the tunnel pushes.
	 *
	 * This is a privacy decision, not a formatting one, so it is spelled out
	 * rather than copied from the configuration:
	 *
	 *  * [DnsMode.VPN] — use exactly what the server pushed, and nothing else.
	 *  * [DnsMode.TRUSTED] — same, but the user's own resolvers are added,
	 *    which is useful when the server's resolver is unreachable.
	 *  * [DnsMode.CUSTOM] — use only the user's resolvers, ignoring the
	 *    server's. A custom list that is empty is a configuration error, not a
	 *    reason to fall back to the server's resolvers, because doing so would
	 *    silently ignore a privacy preference.
	 *
	 * When the resolved list is empty the platform resolver is used, which is
	 * visible to the user's network and is therefore stated in the UI rather
	 * than hidden.
	 */
	private fun applyDns(
		builder: Interface.Builder,
		source: WireGuardConfigKey,
		request: TunnelRequestKey,
	) {
		val servers = LinkedHashSet<String>()
		when (request.dnsMode) {
			DnsMode.VPN -> servers.addAll(source.dns)
			DnsMode.TRUSTED -> {
				servers.addAll(source.dns)
				servers.addAll(request.customDns)
			}

			DnsMode.CUSTOM -> {
				if (request.customDns.isEmpty()) {
					throw WgMappingException(
						"dns.custom_empty",
						"You chose to use your own DNS servers but did not enter any.",
					)
				}
				servers.addAll(request.customDns)
			}
		}

		if (servers.isEmpty()) {
			return
		}
		try {
			builder.parseDnsServers(servers.joinToString(", "))
		} catch (error: BadConfigException) {
			throw WgMappingException(
				"wg.dns_invalid",
				"One of the DNS server addresses for this tunnel is not valid.",
			)
		}
	}

	private fun applyMtu(builder: Interface.Builder, mtu: Int) {
		if (mtu < 576 || mtu > 1500) {
			throw WgMappingException(
				"wg.mtu_invalid",
				"The tunnel's MTU of $mtu is outside the range 576-1500.",
			)
		}
		try {
			builder.parseMtu(mtu.toString())
		} catch (error: BadConfigException) {
			throw WgMappingException("wg.mtu_invalid", "The tunnel's MTU is not valid.")
		}
	}

	private fun applyListenPort(builder: Interface.Builder, port: Int) {
		if (port !in 1..65535) {
			throw WgMappingException(
				"wg.listen_port_invalid",
				"The tunnel's local port of $port is not a valid port number.",
			)
		}
		try {
			builder.parseListenPort(port.toString())
		} catch (error: BadConfigException) {
			throw WgMappingException(
				"wg.listen_port_invalid",
				"The tunnel's local port is not valid.",
			)
		}
	}

	/**
	 * Applies the user's per-app policy.
	 *
	 * Both lists at once is a contradiction the caller is supposed to have
	 * rejected already; it is refused here too rather than silently preferring
	 * one, because guessing which the user meant could exclude the wrong apps
	 * from the tunnel.
	 *
	 * `allowLan` is a different matter and is handled by refusing it. The
	 * official engine builds its interface from this Config alone — it calls
	 * addAddress, addDnsServer and addRoute and nothing else — so there is no
	 * supported way to say "route the private ranges over the physical
	 * interface instead". Accepting the setting and then tunnelling private
	 * ranges anyway would be a silent lie, and tunnelling them when the user
	 * asked to exclude them would be a functional break. The request is
	 * therefore rejected with a reason rather than quietly ignored.
	 */
	private fun applyApplicationFilter(builder: Interface.Builder, request: TunnelRequestKey) {
		if (request.allowLan) {
			throw WgMappingException(
				"routing.allow_lan_unsupported",
				"Keeping local network traffic outside the tunnel is not supported " +
					"on this platform, so the tunnel was not started rather than " +
					"routing your local network against your wishes.",
			)
		}
		val included = request.allowedApps
		val excluded = request.disallowedApps
		if (!included.isNullOrEmpty() && !excluded.isNullOrEmpty()) {
			throw WgMappingException(
				"routing.contradictory_app_lists",
				"This connection asks to include some apps in the tunnel and " +
					"exclude others, which cannot both be true.",
			)
		}
		if (!included.isNullOrEmpty()) {
			builder.parseIncludedApplications(included.joinToString(" "))
		} else if (!excluded.isNullOrEmpty()) {
			builder.parseExcludedApplications(excluded.joinToString(" "))
		}
	}

	/**
	 * Decides the exact route list a peer will install on the device.
	 *
	 * Two independent rules, applied in this order:
	 *
	 *  1. **IPv6 policy.** When IPv6 may not be carried, every IPv6 entry is
	 *     dropped. Each surviving entry becomes an `addRoute` call, so an IPv6
	 *     default route left in place is exactly the leak "block IPv6" exists to
	 *     prevent. IPv6 prefixes other than the default are removed too, so the
	 *     policy is coherent rather than half-applied.
	 *
	 *  2. **Full-tunnel guarantee.** A peer that carries no IPv4 default route
	 *     gets `0.0.0.0/0` added, and likewise `::/0` when IPv6 is permitted.
	 *
	 * The Dart layer already applies the same repair in
	 * `VpnConfiguration.effective`, and that is where the user is told about it.
	 * This is the second of two layers on purpose: the engine's routing is
	 * derived from this list and nothing else, so a configuration that reached
	 * here without passing through the Dart repair — a future call site, a
	 * malformed bridge payload, a partially applied setting — would otherwise
	 * install a silently leaky interface. Belt and braces is the right posture
	 * for the one property that must never fail quietly.
	 */
	private fun buildAllowedIps(
		original: List<String>,
		carryIpv6: Boolean,
		fullTunnel: Boolean,
	): List<String> {
		val filtered = if (carryIpv6) {
			original
		} else {
			original.filterNot { it.contains(':') }
		}
		if (!fullTunnel) {
			return filtered
		}

		val result = ArrayList<String>(filtered.size + 2)
		if (filtered.none { it.trim() == "0.0.0.0/0" }) {
			result.add("0.0.0.0/0")
		}
		if (carryIpv6 && filtered.none { it.trim() == "::/0" }) {
			result.add("::/0")
		}
		result.addAll(filtered)
		return result
	}

	private fun buildPeer(
		peer: WgPeerKey,
		index: Int,
		carryIpv6: Boolean,
		fullTunnel: Boolean,
	): Peer {
		val label = "Peer ${index + 1}"
		val builder = Peer.Builder()

		try {
			builder.parsePublicKey(peer.publicKey)
		} catch (error: BadConfigException) {
			throw WgMappingException(
				"wg.peer.public_key_invalid",
				"$label of the tunnel has a server public key that is not valid.",
			)
		}

		// AllowedIPs become the operating system's routes, so this is where the
		// IPv6 policy and the full-tunnel guarantee both have to bite.
		val allowedIps = buildAllowedIps(peer.allowedIps, carryIpv6, fullTunnel)
		if (allowedIps.isEmpty()) {
			// Never start a peer that would receive no traffic: an empty
			// AllowedIPs is either a mistake or a black hole, and either way the
			// user's traffic would silently bypass the tunnel. This is also what
			// an IPv6-only peer looks like once IPv6 is blocked.
			throw WgMappingException(
				"wg.peer.allowed_ips_missing",
				"$label of the tunnel has no usable IP ranges, so it would receive " +
					"no traffic and everything would bypass the tunnel.",
			)
		}
		try {
			builder.parseAllowedIPs(allowedIps.joinToString(", "))
		} catch (error: BadConfigException) {
			throw WgMappingException(
				"wg.peer.allowed_ips_invalid",
				"$label of the tunnel has an allowed IP range that is not valid.",
			)
		}

		// The endpoint is mandatory here. A peer with no endpoint cannot be
		// dialled; the parser requires one, and a missing value would otherwise
		// leave the tunnel silently unable to connect.
		if (peer.endpointHost.isBlank() || peer.endpointPort !in 1..65535) {
			throw WgMappingException(
				"wg.peer.endpoint_invalid",
				"$label of the tunnel has no usable server address.",
			)
		}
		try {
			builder.parseEndpoint("${peer.endpointHost}:${peer.endpointPort}")
		} catch (error: BadConfigException) {
			throw WgMappingException(
				"wg.peer.endpoint_invalid",
				"$label of the tunnel has a server address that is not valid.",
			)
		}

		peer.presharedKey?.takeIf { it.isNotBlank() }?.let { psk ->
			try {
				builder.parsePreSharedKey(psk)
			} catch (error: BadConfigException) {
				throw WgMappingException(
					"wg.peer.preshared_key_invalid",
					"$label of the tunnel has a pre-shared key that is not valid.",
				)
			}
		}

		peer.persistentKeepalive?.let { keepalive ->
			if (keepalive !in 0..65535) {
				throw WgMappingException(
					"wg.peer.keepalive_invalid",
					"$label of the tunnel has a keepalive value that is not valid.",
				)
			}
			try {
				builder.parsePersistentKeepalive(keepalive.toString())
			} catch (error: BadConfigException) {
				throw WgMappingException(
					"wg.peer.keepalive_invalid",
					"$label of the tunnel has a keepalive value that is not valid.",
				)
			}
		}

		return try {
			builder.build()
		} catch (error: BadConfigException) {
			throw WgMappingException(
				"wg.peer.malformed",
				"$label of the tunnel is incomplete or inconsistent.",
			)
		}
	}
}

/**
 * A configuration that cannot be used, with a code the Dart state machine
 * understands and a message safe to show a user.
 *
 * The cause is deliberately not carried: it is a [BadConfigException], whose
 * message can echo the offending value, and for this payload that value is key
 * material.
 */
internal class WgMappingException(
	val code: String,
	override val message: String,
) : Exception(message)
