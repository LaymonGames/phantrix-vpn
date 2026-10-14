package dev.phantrix.phantrix_platform

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for the request parser's OpenVPN branch.
 *
 * They run on the JVM, which is only possible because the parser's secret-free
 * error paths never touch a platform type — `org.json` and `android.util.Log`
 * are both available on the unit-test classpath, and the code under test never
 * invokes an Android API that has no JVM implementation.
 *
 * What is asserted is the contract with Dart: which payload shapes are
 * accepted, which are refused with which code, and — the part that matters as
 * much — that a refusal never carries the configuration's contents.
 */
class TunnelRequestParserTest {

	private fun openVpnRequest(
		profile: String? = "client\nremote 203.0.113.10 1194",
	): Map<String, Any?> {
		val config = org.json.JSONObject().put("kind", "openVpn")
			.put(
				"openvpn",
				org.json.JSONObject()
					.put("proto", "udp")
					.put("dev", "tun")
					.put(
						"remotes",
						org.json.JSONArray().put(
							org.json.JSONObject()
								.put("host", "203.0.113.10")
								.put("port", 1194)
								.put("proto", "udp"),
						),
					)
					.put("authUserPass", true),
			)
			.toString()
		// Present only when non-null, exactly as `TunnelRequest.toMap` does. Adding
		// the key with a null value would not be the wire format Dart produces, so
		// the test mirrors the producer rather than a convenient shape.
		val profileEntry = if (profile == null) {
			emptyList<Pair<String, Any?>>()
		} else {
			listOf("ovpnConfig" to profile)
		}
		return mapOf(
			"configJson" to config,
			"serverId" to "server-42",
			"countryLabel" to "Test",
			"killSwitch" to "automatic",
			"dnsMode" to "vpn",
			"customDns" to emptyList<String>(),
			"ipv6" to "block",
			"mtu" to null,
			"allowLan" to false,
			"allowedApps" to null,
			"disallowedApps" to null,
			*profileEntry.toTypedArray(),
		)
	}

	@Test
	fun anOpenVpnRequestCarriesItsProfileForward() {
		val parsed = TunnelRequestParser.parse(openVpnRequest())
		assertTrue(parsed.isOpenVpn)
		assertEquals("client\nremote 203.0.113.10 1194", parsed.ovpnConfig)
	}

	@Test
	fun anOpenVpnRequestWithoutAProfileIsRefusedRatherThanStartedEmpty() {
		// The profile is the only thing the engine is told to run. Starting one
		// from nothing would be connecting to an undefined server.
		var code: String? = null
		try {
			TunnelRequestParser.parse(openVpnRequest(profile = null))
		} catch (error: TunnelRequestException) {
			code = error.code
		}
		assertEquals("ovpn.config_missing", code)
	}

	@Test
	fun aBlankProfileIsTreatedTheSameAsAMissingOne() {
		var code: String? = null
		try {
			TunnelRequestParser.parse(openVpnRequest(profile = "   \n  "))
		} catch (error: TunnelRequestException) {
			code = error.code
		}
		assertEquals("ovpn.config_missing", code)
	}

	@Test
	fun aWireGuardRequestWithoutAProfileIsStillAccepted() {
		val peer = org.json.JSONObject()
			.put("publicKey", "iGaPncC709q7zIxUD9OMJENN3dh+W40oQx0Lv7AStp8=")
			.put("endpoint", "192.0.2.1:51820")
			.put("allowedIps", org.json.JSONArray().put("0.0.0.0/0"))
		val wireguard = org.json.JSONObject()
			.put("privateKey", "02R31BtVMJe/5r8cMd8uRVf6DysDrWKFXxDlMdRDU6c=")
			.put("addresses", org.json.JSONArray().put("10.8.0.2/32"))
			.put("peers", org.json.JSONArray().put(peer))
		val request = mapOf(
			"configJson" to org.json.JSONObject()
				.put("kind", "wireGuard")
				.put("wireguard", wireguard)
				.toString(),
			"serverId" to "server-1",
			"countryLabel" to "Test",
			"killSwitch" to "off",
			"dnsMode" to "vpn",
			"customDns" to emptyList<String>(),
			"ipv6" to "block",
			"mtu" to null,
			"allowLan" to false,
			"allowedApps" to null,
			"disallowedApps" to null,
		)
		val parsed = TunnelRequestParser.parse(request)
		assertFalse(parsed.isOpenVpn)
		assertEquals(null, parsed.ovpnConfig)
	}

	@Test
	fun arefusalNeverCarriesTheProfileText() {
		// The exception's message becomes the reason shown to the user. A profile
		// is a certificate, a key and a credential; a message that echoed it
		// would put all three in a dialog, and into any error report built from
		// one.
		var message: String? = null
		try {
			// Force the refusal by omitting the profile from a request that has
			// the OpenVPN block, so the parse fails on the missing text.
			TunnelRequestParser.parse(openVpnRequest(profile = null))
		} catch (error: TunnelRequestException) {
			message = error.message
		}
		assertTrue("the refusal was silent", message != null)
		assertFalse(
			"the refusal message echoed the profile: $message",
			(message ?: "").contains("203.0.113.10") || (message ?: "").contains("remote"),
		)
	}

	@Test
	fun theRequestRefusesBothAppListsRatherThanPickingOne() {
		val base = openVpnRequest().toMutableMap()
		base["allowedApps"] = listOf("com.example.a")
		base["disallowedApps"] = listOf("com.example.b")
		var message: String? = null
		try {
			TunnelRequestParser.parse(base)
		} catch (error: IllegalArgumentException) {
			message = error.message
		}
		// The reason, not the package names.
		assertTrue(message != null)
		assertFalse(
			"a package name leaked into the refusal: $message",
			(message ?: "").contains("com.example.a") ||
				(message ?: "").contains("com.example.b"),
		)
	}

	@Test
	fun aNonMapRequestIsRefusedRatherThanDefaulted() {
		var message: String? = null
		try {
			TunnelRequestParser.parse("not a map at all")
		} catch (error: IllegalArgumentException) {
			message = error.message
		}
		assertTrue(message != null)
	}

	@Test
	fun thePolicyFieldsSurviveTheParse() {
		val base = openVpnRequest().toMutableMap()
		base["ipv6"] = "allow"
		base["dnsMode"] = "custom"
		base["customDns"] = listOf("9.9.9.9", "1.1.1.1")
		base["mtu"] = 1380
		base["allowLan"] = true
		val parsed = TunnelRequestParser.parse(base)

		// Every one of these is a decision the user made. If any of them were
		// dropped here, the policy would be parsed, displayed in the UI, and then
		// silently ignored by the tunnel — which is the failure mode the native
		// OpenVPN profile factory exists to prevent.
		//
		// `customDns` in particular arrives as a `List` over the method channel,
		// the same shape `TunnelRequest.toMap` produces, and not as the `JSONArray`
		// the parser used to accept. Accepting only the JSON form would have
		// silently turned every custom-DNS request into "no servers given".
		assertEquals(Ipv6Policy.ALLOW, parsed.ipv6)
		assertEquals(DnsMode.CUSTOM, parsed.dnsMode)
		assertEquals(listOf("9.9.9.9", "1.1.1.1"), parsed.customDns)
		assertEquals(1380, parsed.mtu)
		assertTrue(parsed.allowLan)
	}

	@Test
	fun thePerAppListsSurviveTheParse() {
		val included = openVpnRequest().toMutableMap()
		included["allowedApps"] = listOf("com.example.a")
		val parsed = TunnelRequestParser.parse(included)
		assertEquals(setOf("com.example.a"), parsed.allowedApps)

		val excluded = openVpnRequest().toMutableMap()
		excluded["disallowedApps"] = listOf("com.example.b")
		assertEquals(
			setOf("com.example.b"),
			TunnelRequestParser.parse(excluded).disallowedApps,
		)
	}
}
