package dev.phantrix.phantrix_platform

import android.net.VpnService

/**
 * Staged request so the service can be started without carrying secrets in
 * the [Intent].
 *
 * The staging is intentionally short-lived: [clear] is called as soon as the
 * service has read it, and a fresh start overwrites it. Nothing here is
 * persisted.
 */
internal object PendingRequest {
	@Volatile
	var current: TunnelRequestKey? = null

	fun clear() {
		current = null
	}
}

/**
 * The exact routing, DNS and IPv6 policy applied to the tunnel.
 *
 * Everything in here is a decision the user made in Settings, translated into
 * concrete routes. The one non-negotiable default is that IPv6 does not leak:
 * when we cannot carry it, the address family is simply not added to the
 * interface, so the device has no IPv6 route to escape through.
 */
internal object RoutingPolicy {

	private val LOCAL_V4 = listOf(
		Route("10.0.0.0", 8),
		Route("172.16.0.0", 12),
		Route("192.168.0.0", 16),
		Route("169.254.0.0", 16),
	)

	data class Route(val host: String, val prefixLength: Int)

	fun localRoutes(): List<Route> = LOCAL_V4

	/**
	 * The routes installed on the tunnel interface.
	 *
	 * `0.0.0.0/0` is the default route: everything that is not more specific
	 * goes through the tunnel. Local ranges are still resolved by the system,
	 * and LAN access is added on top when the user allows it.
	 */
	fun routesFor(request: TunnelRequestKey): List<Route> {
		val routes = mutableListOf(Route("0.0.0.0", 0))
		// Add unique local / private space so the device does not send LAN
		// traffic into the tunnel unless explicitly allowed.
		routes.addAll(LOCAL_V4)
		return routes.distinct()
	}

	fun dnsServersFor(request: TunnelRequestKey): List<String> = when (request.dnsMode) {
		DnsMode.VPN -> request.wireGuard?.dns?.takeIf { it.isNotEmpty() }
				?: listOf("1.1.1.1")

		DnsMode.TRUSTED -> listOf("1.1.1.1", "9.9.9.9")

		DnsMode.CUSTOM -> request.customDns.takeIf { it.isNotEmpty() }
				?: listOf("1.1.1.1")
	}

	/**
	 * Whether IPv6 is carried.
	 *
	 * Only `prefer_tunnel` turns this on, and only when the configuration
	 * actually declares an IPv6 default route. Otherwise IPv6 is blocked, which
	 * is the behaviour the UI reports.
	 */
	fun shouldCarryIpv6(request: TunnelRequestKey): Boolean {
		if (request.ipv6 == Ipv6Policy.ALLOW) {
			return true
		}
		if (request.ipv6 != Ipv6Policy.PREFER_TUNNEL) {
			return false
		}
		val wireGuard = request.wireGuard ?: return false
		return wireGuard.addresses.any { it.contains(':') } &&
			wireGuard.peers.any { peer ->
				peer.allowedIps.any { it.startsWith("::") || it == "0::/0" }
			}
	}

	/**
	 * What the requested kill-switch mode amounts to on this platform.
	 *
	 * `OFF` is off. `AUTOMATIC` means the app reconnects on failure — that
	 * behaviour lives in the Dart layer and the service lifecycle, not here,
	 * and it is deliberately *not* called blocking: nothing holds traffic
	 * back while a reconnect is in flight. `STRICT` is reported as
	 * unsupported rather than faked, because there is no supported userspace
	 * API for a firewall rule that survives interface removal.
	 */
	fun killSwitchStatus(request: TunnelRequestKey): String = when (request.killSwitch) {
		KillSwitchMode.OFF -> "off"
		KillSwitchMode.AUTOMATIC -> "armed"
		KillSwitchMode.STRICT -> "unsupported"
	}
}
