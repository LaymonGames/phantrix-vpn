package dev.phantrix.phantrix_platform

import android.util.Log
import org.json.JSONArray
import org.json.JSONObject

/**
 * Deserialises the tunnel request that Dart sends.
 *
 * Every field is validated on arrival. A malformed request is rejected with
 * an explicit reason rather than defaulting to something unsafe: for example,
 * a missing [Ipv6Policy] never silently means "allow IPv6".
 *
 * This class performs no networking and holds no secrets in string form beyond
 * the wrapped configuration, which is never logged.
 */
internal data class TunnelRequestKey(
	val serverId: String,
	val countryLabel: String,
	val killSwitch: KillSwitchMode,
	val dnsMode: DnsMode,
	val customDns: List<String>,
	val ipv6: Ipv6Policy,
	val mtu: Int?,
	val wireGuard: WireGuardConfigKey?,
	val openVpn: OpenVpnConfigKey?,
	val allowedApps: Set<String>?,
	val disallowedApps: Set<String>?,
	val allowLan: Boolean,
	/**
	 * The complete `.ovpn` profile text, as [TunnelRequest.ovpnConfig] on the Dart
	 * side, or null for WireGuard.
	 *
	 * It is the single source of what the engine is told: the structured
	 * [openVpn] block exists so the request can be validated and so the app can
	 * tell the two protocols apart, but the profile text is what is parsed. Both
	 * are already validated in Dart; the native side still re-checks the profile
	 * text for execution-capable directives before handing it to the engine.
	 */
	val ovpnConfig: String?,
) {
	/** True when this request is for an OpenVPN tunnel. */
	val isOpenVpn: Boolean get() = openVpn != null
}

internal enum class KillSwitchMode(value: String) {
	OFF("off"),
	AUTOMATIC("automatic"),
	STRICT("strict");

	companion object {
		fun parse(value: String?): KillSwitchMode = when (value) {
			"strict" -> STRICT
			"automatic" -> AUTOMATIC
			"off" -> OFF
			else -> AUTOMATIC
		}
	}
}

internal enum class DnsMode(value: String) {
	VPN("vpn"),
	TRUSTED("trusted"),
	CUSTOM("custom");

	companion object {
		fun parse(value: String?): DnsMode = when (value) {
			"trusted" -> TRUSTED
			"custom" -> CUSTOM
			"vpn" -> VPN
			else -> VPN
		}
	}
}

/**
 * What happens to IPv6 traffic while the tunnel is up.
 *
 * [BLOCK] is the safe default: an address that cannot leave the device is not
 * a leak, and the app tells the user that is what happened.
 */
internal enum class Ipv6Policy(value: String) {
	PREFER_TUNNEL("prefer_tunnel"),
	BLOCK("block"),
	ALLOW("allow");

	companion object {
		fun parse(value: String?): Ipv6Policy = when (value) {
			"allow" -> ALLOW
			"block" -> BLOCK
			"prefer_tunnel" -> PREFER_TUNNEL
			else -> BLOCK
		}
	}
}

internal data class WireGuardConfigKey(
	val privateKey: String,
	val addresses: List<String>,
	val dns: List<String>,
	val mtu: Int?,
	val listenPort: Int?,
	val peers: List<WgPeerKey>,
)

internal data class WgPeerKey(
	val publicKey: String,
	val presharedKey: String?,
	val endpointHost: String,
	val endpointPort: Int,
	val allowedIps: List<String>,
	val persistentKeepalive: Int?,
)

internal data class OpenVpnConfigKey(
	val proto: String,
	val dev: String,
	val cipher: String?,
	val auth: String?,
	val remotes: List<OvpnRemoteKey>,
	val ca: String?,
	val cert: String?,
	val key: String?,
	val tlsAuth: String?,
	val authUserPass: Boolean,
)

internal data class OvpnRemoteKey(
	val host: String,
	val port: Int,
	val proto: String?,
)

/** A request that parsed but cannot be honoured, with a code Dart understands. */
internal class TunnelRequestException(
	val code: String,
	override val message: String,
) : IllegalArgumentException(message)

/** Parses the JSON envelope. Throws [IllegalArgumentException] with a reason. */
internal object TunnelRequestParser {

	private const val TAG = "PhantrixRequest"

	fun parse(payload: Any?): TunnelRequestKey {
		val root = payload as? Map<*, *>
				?: throw IllegalArgumentException("The tunnel request was not a map.")
		val config = root["configJson"] as? String
				?: throw IllegalArgumentException("The tunnel request carried no configuration.")

		val json = try {
			JSONObject(config)
		} catch (error: Exception) {
			// The exception is deliberately NOT logged. org.json puts the
			// offending value into its message, and that value is the tunnel
			// configuration, which contains the private key. Log the type only.
			Log.w(TAG, "Configuration JSON could not be read: ${error.javaClass.simpleName}")
			throw IllegalArgumentException("The tunnel configuration was unreadable.")
		}

		val wireGuard = json.optJSONObject("wireguard")
		val openVpn = json.optJSONObject("openvpn")

		val wg = if (wireGuard != null) parseWireGuard(wireGuard) else null
		val ovpn = if (openVpn != null) parseOpenVpn(openVpn) else null

		when {
			wg == null && ovpn == null ->
				throw IllegalArgumentException(
					"The configuration named neither WireGuard nor OpenVPN.",
				)
			wg != null && ovpn != null ->
				throw IllegalArgumentException(
					"The configuration named two protocols at once.",
				)
		}

		val ipv6 = Ipv6Policy.parse(root["ipv6"] as? String)
		if (ipv6 == Ipv6Policy.ALLOW) {
			Log.i(TAG, "IPv6 is set to allow. The user must have accepted the leak.")
		}

		val allowed = stringSet(root["allowedApps"])
		val disallowed = stringSet(root["disallowedApps"])
		if (allowed != null && disallowed != null) {
			throw IllegalArgumentException(
				"Only one of allowedApps and disallowedApps may be set.",
			)
		}

		// The `.ovpn` text is only meaningful for an OpenVPN request, and is
		// mandatory for one. It is the profile the engine will actually be told
		// to run, so a request without it cannot be started rather than started
		// from a profile that does not exist.
		val profile = (root["ovpnConfig"] as? String)?.takeIf { it.isNotBlank() }
		if (ovpn != null && profile == null) {
			throw TunnelRequestException(
				"ovpn.config_missing",
				"The request carried no OpenVPN profile, so no tunnel can be " +
					"started. Reconnect from the app.",
			)
		}
		if (profile != null && ovpn == null) {
			// Not a reason to refuse: a WireGuard request that also carries a
			// profile is a client quirk, and the profile is simply unused. Logged
			// because a payload shape nothing produces is worth knowing about.
			Log.i(TAG, "A WireGuard request carried an unused OpenVPN profile.")
		}

		return TunnelRequestKey(
			serverId = root["serverId"] as? String ?: "",
			countryLabel = root["countryLabel"] as? String ?: "",
			killSwitch = KillSwitchMode.parse(root["killSwitch"] as? String),
			dnsMode = DnsMode.parse(root["dnsMode"] as? String),
			customDns = stringList(root["customDns"]),
			ipv6 = ipv6,
			mtu = (root["mtu"] as? Number)?.toInt(),
			wireGuard = wg,
			openVpn = ovpn,
			allowedApps = allowed,
			disallowedApps = disallowed,
			allowLan = root["allowLan"] as? Boolean ?: false,
			ovpnConfig = profile,
		)
	}

	private fun parseWireGuard(json: JSONObject): WireGuardConfigKey {
		val privateKey = json.optString("privateKey")
		if (privateKey.isEmpty()) {
			throw IllegalArgumentException("WireGuard configuration has no private key.")
		}
		val addresses = stringList(json.optJSONArray("addresses"))
		if (addresses.isEmpty()) {
			throw IllegalArgumentException("WireGuard configuration has no interface address.")
		}
		val peersArray = json.optJSONArray("peers")
				?: throw IllegalArgumentException("WireGuard configuration has no peers.")
		val peers = mutableListOf<WgPeerKey>()
		for (index in 0 until peersArray.length()) {
			val peer = peersArray.optJSONObject(index)
					?: throw IllegalArgumentException("A peer was not an object.")
			val publicKey = peer.optString("publicKey")
			if (publicKey.isEmpty()) {
				throw IllegalArgumentException("A peer has no public key.")
			}
			val endpoint = peer.optString("endpoint")
			if (endpoint.isEmpty()) {
				throw IllegalArgumentException("A peer has no endpoint.")
			}
			peers.add(
				WgPeerKey(
					publicKey = publicKey,
					presharedKey = peer.optString("presharedKey").ifEmpty { null },
					endpointHost = endpointHostOf(endpoint),
					endpointPort = endpointPortOf(endpoint),
					allowedIps = stringList(peer.optJSONArray("allowedIps")),
					persistentKeepalive = (peer.optInt("persistentKeepalive", 0))
						.takeIf { it > 0 },
				),
			)
		}
		if (peers.isEmpty()) {
			throw IllegalArgumentException("WireGuard configuration has no usable peers.")
		}
		return WireGuardConfigKey(
			privateKey = privateKey,
			addresses = addresses,
			dns = stringList(json.optJSONArray("dns")),
			mtu = json.optInt("mtu").takeIf { it > 0 },
			listenPort = json.optInt("listenPort").takeIf { it > 0 },
			peers = peers,
		)
	}

	private fun parseOpenVpn(json: JSONObject): OpenVpnConfigKey {
		val remotesArray = json.optJSONArray("remotes")
				?: throw IllegalArgumentException("OpenVPN configuration has no remotes.")
		val remotes = mutableListOf<OvpnRemoteKey>()
		for (index in 0 until remotesArray.length()) {
			val remote = remotesArray.optJSONObject(index)
					?: throw IllegalArgumentException("A remote was not an object.")
			val host = remote.optString("host")
			val port = remote.optInt("port")
			if (host.isEmpty() || port <= 0) {
				continue
			}
			remotes.add(
				OvpnRemoteKey(
					host = host,
					port = port,
					proto = remote.optString("proto").ifEmpty { null },
				),
			)
		}
		if (remotes.isEmpty()) {
			throw IllegalArgumentException("OpenVPN configuration has no usable remotes.")
		}
		return OpenVpnConfigKey(
			proto = json.optString("proto").ifEmpty { "udp" },
			dev = json.optString("dev").ifEmpty { "tun" },
			cipher = json.optString("cipher").ifEmpty { null },
			auth = json.optString("auth").ifEmpty { null },
			remotes = remotes,
			ca = json.optString("ca").ifEmpty { null },
			cert = json.optString("cert").ifEmpty { null },
			key = json.optString("key").ifEmpty { null },
			tlsAuth = json.optString("tlsAuth").ifEmpty { null },
			authUserPass = json.optBoolean("authUserPass", false),
		)
	}

	private fun endpointHostOf(endpoint: String): String {
		val bracket = endpoint.lastIndexOf(']')
		if (endpoint.startsWith("[") && bracket > 0) {
			return endpoint.substring(1, bracket)
		}
		val colon = endpoint.lastIndexOf(':')
		if (colon < 0) {
			return endpoint
		}
		// A bare IPv6 address with no port.
		if (endpoint.count { it == ':' } >= 2) {
			return endpoint
		}
		return endpoint.substring(0, colon)
	}

	private fun endpointPortOf(endpoint: String): Int {
		val bracket = endpoint.lastIndexOf(']')
		val start = if (endpoint.startsWith("[") && bracket > 0) bracket + 1 else 0
		val colon = endpoint.lastIndexOf(':')
		if (colon <= start) {
			return 51820
		}
		return endpoint.substring(colon + 1).trim().toIntOrNull() ?: 51820
	}

	private fun stringList(value: Any?): List<String> {
		// `customDns` arrives over the method channel as a Kotlin/Flutter
		// `List<String>`, not a `JSONArray`: the envelope is a `Map`, and `org.json`
		// is only involved for the *nested* `configJson` string. Accepting both
		// shapes is what keeps the parser working regardless of which encoding the
		// caller's method-channel plumbing used.
		//
		// The `JSONArray` form is still handled because `TunnelJson`'s shape is a
		// Kotlin map that the embedder may hand over as either.
		if (value is List<*>) {
			return value.mapNotNull { it as? String }
		}
		if (value !is JSONArray) {
			return emptyList()
		}
		val out = mutableListOf<String>()
		for (index in 0 until value.length()) {
			val entry = value.optString(index)
			if (entry.isNotEmpty()) {
				out.add(entry)
			}
		}
		return out
	}

	private fun stringSet(value: Any?): Set<String>? {
		val list = value as? List<*> ?: return null
		return list.mapNotNull { it as? String }.filter { it.isNotEmpty() }.toSet()
	}
}
