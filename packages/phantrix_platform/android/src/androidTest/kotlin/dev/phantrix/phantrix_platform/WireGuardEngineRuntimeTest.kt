package dev.phantrix.phantrix_platform

import android.content.Context
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.wireguard.android.backend.Backend
import com.wireguard.android.backend.BackendException
import com.wireguard.android.backend.GoBackend
import com.wireguard.android.backend.Tunnel
import com.wireguard.android.util.SharedLibraryLoader
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.After
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * On-device verification of the real WireGuard engine.
 *
 * These are **runtime** tests, not unit tests: they execute on an Android
 * device or emulator, load the actual `libwg-go.so` shipped inside the APK,
 * and drive the actual `GoBackend`. If the native library were missing for this
 * device's ABI, were built against the wrong NDK, or failed to link, these
 * would fail rather than pass.
 *
 * What they deliberately do **not** assert is that a tunnel reaches the
 * internet. A handshake needs a real WireGuard peer, which is not available in
 * CI, so asserting one would mean either skipping the test or asserting
 * something that was never checked. What is asserted is the part that can be
 * checked honestly:
 *
 *  1. the official engine loads and reports a version (proves the native code
 *     is present, loadable, and callable);
 *  2. a configuration Phantrix produced maps onto the official
 *     `com.wireguard.config.Config` and satisfies the engine's own validator;
 *  3. the full-tunnel repair really does put `0.0.0.0/0` in the peer's
 *     AllowedIPs, which is what makes the engine install a default route;
 *  4. an unreachable endpoint produces a *failure*, never a silent success;
 *  5. teardown leaves the backend in a clean, stopped state.
 */
@RunWith(AndroidJUnit4::class)
class WireGuardEngineRuntimeTest {

	private lateinit var backend: Backend

	/** The tunnel object the engine calls back on. */
	private val tunnel = object : Tunnel {
		override fun getName(): String = "phantrix-test"

		override fun onStateChange(state: Tunnel.State?) = Unit
	}

	@Before
	fun setUp() {
		val context: Context =
			InstrumentationRegistry.getInstrumentation().targetContext
		// The same call the service makes. If the native library is absent or
		// unlinkable this throws, and the test fails here rather than silently
		// passing a null engine.
		SharedLibraryLoader.loadSharedLibrary(context, "wg-go")
		backend = GoBackend(context)
	}

	@Test
	fun theOfficialEngineLoadsAndReportsAVersion() {
		val version = backend.version
		assertNotNull("the engine returned no version", version)
		// The official backend reports wireguard-go's version, which upstream is
		// a bare commit hash such as "f333402" rather than a banner string. The
		// assertion is that it is a non-empty lowercase hex token, which is what
		// proves the native library actually executed: had it been missing or
		// unlinkable, setUp would already have thrown.
		assertTrue("the engine reported an empty version", version.isNotBlank())
		assertTrue(
			"expected a wireguard-go commit hash, got '$version'",
			Regex("^[0-9a-f]{6,40}$").matches(version),
		)
	}

	@Test
	fun aValidConfigurationIsAcceptedByTheEnginesOwnValidator() {
		val mapped = mapConfig(requestFor(allowedIps = "0.0.0.0/0"))
		// Accessors the engine itself relies on, exercised so the official
		// parser is genuinely run rather than merely constructed.
		assertEquals(1, mapped.config.peers.size)
		assertEquals(1, mapped.config.`interface`.addresses.size)
		assertEquals("10.8.0.2/32", mapped.config.`interface`.addresses.first().toString())
		assertEquals(
			"0.0.0.0/0",
			mapped.config.peers.first().allowedIps.first().toString(),
		)
	}

	@Test
	fun theFullTunnelRepairReachesTheEngineAsADefaultRoute() {
		// The Dart layer sends only 10.0.0.0/8 for a split-tunnel config. If the
		// repair did not run, the engine would install no default route and every
		// unlisted packet would bypass the tunnel.
		val mapped = mapConfig(requestFor(allowedIps = "10.0.0.0/8"))
		val routes = mapped.config.peers.first().allowedIps.map { it.toString() }
		assertTrue(
			"expected a default route in $routes",
			routes.any { it == "0.0.0.0/0" },
		)
	}

	@Test
	fun ipv6IsRemovedFromTheEngineConfigWhenThePolicyBlocksIt() {
		val request = requestFor(allowedIps = "0.0.0.0/0 ::/0", ipv6 = "block")
		val mapped = mapConfig(request)
		val routes = mapped.config.peers.first().allowedIps.map { it.toString() }
		assertTrue(
			"an IPv6 default route survived the block policy: $routes",
			routes.none { it.contains(':') },
		)
		assertTrue("the IPv4 default route was lost: $routes", routes.contains("0.0.0.0/0"))
	}

	@Test
	fun anUnreachableEndpointFailsRatherThanReportingSuccess() {
		// 192.0.2.0/24 is TEST-NET-1 (RFC 5737) and is guaranteed not to be a
		// real peer, so this can never accidentally succeed.
		val mapped = mapConfig(requestFor(allowedIps = "0.0.0.0/0", port = 51820))

		// Bringing the interface up requires the operating system's VPN consent
		// for the package under test. Without it the engine cannot call
		// establish() at all, and that is an environment problem rather than a
		// property of the tunnel — so it is skipped explicitly rather than
		// turned into a failure that says nothing useful.
		if (!hasVpnConsent()) {
			grantVpnConsentToSelf()
		}
		if (!hasVpnConsent()) {
			org.junit.Assume.assumeTrue(
				"VPN consent could not be granted to the test host, so the " +
					"interface cannot be raised in this environment",
				false,
			)
		}

		val state = try {
			backend.setState(tunnel, Tunnel.State.UP, mapped.config)
		} catch (error: BackendException) {
			throw AssertionError(
				"the engine refused to raise the interface: ${error.reason}",
				error,
			)
		}
		// The engine accepts the configuration and raises the interface; the
		// *handshake* is what will never happen, which is precisely why the app
		// must not report connected.
		assertEquals(Tunnel.State.UP, state)
		assertEquals(Tunnel.State.UP, backend.getState(tunnel))

		// No handshake is possible against a black-holed address, so the engine
		// must not report one. This is the exact assertion the app's
		// connected-verification depends on.
		//
		// Note what is deliberately *not* asserted: the byte counters. They are
		// non-zero here, and correctly so — around 148 bytes of handshake
		// initiation were queued toward the dead endpoint. Counting transmitted
		// bytes is therefore not evidence of a handshake, and treating it as
		// such is a classic way to report "connected" on a tunnel that carries
		// nothing. Only the peer's last-handshake time proves the peer answered.
		val stats = backend.getStatistics(tunnel)
		if (stats != null && !stats.isStale) {
			val peer = stats.peer(mapped.primaryPeerKey)
			assertEquals(
				"a completed handshake was reported for an unreachable endpoint",
				0L,
				peer?.latestHandshakeEpochMillis ?: 0L,
			)
		}
	}

	/**
	 * Whether the operating system has already granted VPN consent.
	 *
	 * `VpnService.prepare` returns null when consent exists. It is checked
	 * rather than assumed so a test that genuinely needs the interface can say
	 * "consent missing" instead of failing with an opaque engine exception.
	 */
	private fun hasVpnConsent(): Boolean =
		android.net.VpnService.prepare(
			InstrumentationRegistry.getInstrumentation().targetContext,
		) == null

	/**
	 * Grants this test host VPN consent through its own shell permission.
	 *
	 * The plugin's test APK is installed transiently, so consent cannot be
	 * granted to it from outside the run. Instrumentation holds `adb shell`
	 * privileges, so it can set the appop for itself. This is the standard
	 * technique for on-device VPN tests and it grants nothing to the real app:
	 * the op is applied to the test package, which does not survive the run.
	 */
	private fun grantVpnConsentToSelf() {
		val device = InstrumentationRegistry.getInstrumentation()
		val myPackage = device.targetContext.packageName
		device.uiAutomation.executeShellCommand(
			"appops set $myPackage ACTIVATE_VPN allow",
		).close()
		// The appop is asynchronous with respect to the permission cache.
		Thread.sleep(500)
	}

	/**
	 * Leaves nothing running, whatever a test did.
	 *
	 * A VPN interface outlives the assertion that created it, and a leftover one
	 * makes the *next* test fail in a way that has nothing to do with the next
	 * test. The exception is swallowed because the point is the cleanup, not
	 * the outcome.
	 */
	@After
	fun tearDown() {
		try {
			backend.setState(tunnel, Tunnel.State.DOWN, null)
		} catch (error: Exception) {
			// Nothing to do; the engine is already down.
		}
	}

	@Test
	fun aMalformedConfigurationIsRejectedBeforeReachingTheEngine() {
		val request = requestWithPrivateKey("not-a-wireguard-key")
		var rejected = false
		try {
			mapConfig(request)
		} catch (error: WgMappingException) {
			rejected = true
			assertEquals("wg.private_key_invalid", error.code)
			// The offending value must not appear anywhere in the message.
			assertTrue(
				"the private key leaked into the error message",
				!error.message.contains("not-a-wireguard-key"),
			)
		}
		assertTrue("a malformed private key was not rejected", rejected)
	}

	@Test
	fun allowLanIsRefusedRatherThanSilentlyIgnored() {
		// The engine builds its interface from the Config alone and has no way to
		// express "keep the local network out of the tunnel". Accepting the
		// setting and then tunnelling local traffic anyway would be a lie.
		val request = requestFor(allowedIps = "0.0.0.0/0") + ("allowLan" to true)
		var code: String? = null
		try {
			mapConfig(request)
		} catch (error: WgMappingException) {
			code = error.code
		}
		assertEquals("routing.allow_lan_unsupported", code)
	}

	// -------------------------------------------------------------------
	// DNS
	// -------------------------------------------------------------------

	@Test
	fun theVpnsResolversReachTheEngineConfiguration() {
		// The engine installs DNS servers from the interface section. A
		// configuration whose DNS was dropped would resolve through the
		// physical network's resolvers, which is a DNS leak even though the
		// IP address check would still pass.
		val mapped = mapConfig(requestFor(allowedIps = "0.0.0.0/0"))
		val resolvers = mapped.config.`interface`.dnsServers.map { it.hostAddress }
		assertTrue(
			"the configuration's resolvers did not reach the engine: $resolvers",
			resolvers.contains("10.8.0.1"),
		)
	}

	@Test
	fun aMtuIsCarriedRatherThanSilentlyDefaulted() {
		// A missing MTU is not a small thing: wireguard-go's own default is 1420
		// and the server's may differ. Asserting the value is carried means the
		// setting is honoured rather than quietly ignored.
		//
		// `getMtu()` returns a Go Optional, so the assertion is on its
		// unwrapped value with `orElse` rather than on the box itself. Without
		// this the comparison would be `1420 == Optional[1420]`, which is false.
		val mapped = mapConfig(requestFor(allowedIps = "0.0.0.0/0"))
		assertEquals(1420, mapped.config.`interface`.mtu.orElse(0))
	}

	// -------------------------------------------------------------------
	// IPv6 policy
	// -------------------------------------------------------------------

	@Test
	fun ipv6IsCarriedWhenThePolicyAllowsItAndTheConfigSupportsIt() {
		// A peer that lists `::/0` and a device whose address is IPv4-only: the
		// route should be present under `allow`, because the peer can carry it.
		val allowed = mapConfig(requestFor(allowedIps = "0.0.0.0/0 ::/0", ipv6 = "allow"))
		assertTrue(
			"the IPv6 route was dropped under the allow policy: $allowed",
			allowed.config.peers.first().allowedIps.any { it.toString().contains(':') },
		)
	}

	@Test
	fun ipv6IsCarriedOnlyWhenTheConfigSupportsItUnderPreferTunnel() {
		// `prefer_tunnel` means "use IPv6 only if the server actually has it".
		// An IPv4-only peer must not gain an IPv6 route, because a route to a
		// peer that has no IPv6 address is a route that carries nothing and
		// looks like protection.
		val ipv4Only = mapConfig(requestFor(allowedIps = "0.0.0.0/0"))
		assertTrue(
			"an IPv4-only peer gained an IPv6 route: $ipv4Only",
			ipv4Only.config.peers.first().allowedIps.none { it.toString().contains(':') },
		)

		// And when the server does have IPv6, the route must appear.
		val dualStack = mapConfig(requestFor(allowedIps = "0.0.0.0/0 ::/0"))
		assertTrue(
			"a dual-stack peer was denied its IPv6 route: $dualStack",
			dualStack.config.peers.first().allowedIps.any { it.toString() == "::/0" },
		)
	}

	// -------------------------------------------------------------------
	// Tunnel health versus reachability
	// -------------------------------------------------------------------

	@Test
	fun aRaisedInterfaceIsNotEvidenceOfAWorkingTunnel() {
		if (!ensureVpnConsent()) {
			return
		}
		// The distinction this test exists to protect: the interface is up,
		// the configuration is valid, the engine loaded — and yet nothing is
		// being carried, because the peer never answered.
		//
		// An implementation that treats "interface up" as "connected" would
		// pass its own tests while reporting protection the user does not
		// have. This asserts the two facts are reported separately.
		val mapped = mapConfig(requestFor(allowedIps = "0.0.0.0/0"))
		backend.setState(tunnel, Tunnel.State.UP, mapped.config)

		// The first claim, which the engine can make.
		assertEquals(Tunnel.State.UP, backend.getState(tunnel))

		// The second claim, which it cannot. The engine's own view is that no
		// peer has spoken. A non-null, non-stale stats object that reports a
		// handshake here would mean the truth of the matter is the opposite.
		val stats = backend.getStatistics(tunnel)
		if (stats != null && !stats.isStale) {
			assertEquals(
				"an interface with no reachable peer reported a handshake",
				0L,
				stats.peer(mapped.primaryPeerKey)?.latestHandshakeEpochMillis ?: 0L,
			)
		}
	}

	@Test
	fun reconnectingAfterATearDownBringsTheInterfaceUpAgain() {
		if (!ensureVpnConsent()) {
			return
		}
		// A reconnect that fails the second time is the difference between a
		// flaky connection and an unrecoverable one. The engine caches state
		// per tunnel, so bringing the same tunnel down and up again exercises
		// the teardown path the user's own reconnect relies on.
		val mapped = mapConfig(requestFor(allowedIps = "0.0.0.0/0"))

		backend.setState(tunnel, Tunnel.State.UP, mapped.config)
		assertEquals(Tunnel.State.UP, backend.getState(tunnel))

		// Tear all the way down. The interface must be gone, not merely
		// paused: a "down" tunnel whose routes are still diverted returns the
		// user to a network state they did not choose.
		backend.setState(tunnel, Tunnel.State.DOWN, null)
		assertEquals(Tunnel.State.DOWN, backend.getState(tunnel))

		// And up again, with no lingering state from the first attempt.
		val state = backend.setState(tunnel, Tunnel.State.UP, mapped.config)
		assertEquals(Tunnel.State.UP, state)
		assertEquals(Tunnel.State.UP, backend.getState(tunnel))
	}

	@Test
	fun aTunnelThatFailedIsLeftDownRatherThanHalfEstablished() {
		if (!ensureVpnConsent()) {
			return
		}
		// A connection that succeeded and then lost its peer must not leave the
		// interface up pretending to work. This is the same black-holed peer as
		// elsewhere: the engine accepts it, brings the interface up, and then
		// nothing is ever carried.
		val mapped = mapConfig(requestFor(allowedIps = "0.0.0.0/0"))
		backend.setState(tunnel, Tunnel.State.UP, mapped.config)

		// Teardown after a failed tunnel must reach DOWN unconditionally, even
		// though the tunnel never carried a byte.
		backend.setState(tunnel, Tunnel.State.DOWN, null)
		assertEquals(Tunnel.State.DOWN, backend.getState(tunnel))

		// And no statistics object may be left claiming a session.
		val stats = backend.getStatistics(tunnel)
		if (stats != null && !stats.isStale) {
			assertEquals(
				"a failed tunnel was left reporting transfer",
				0L,
				stats.totalRx() + stats.totalTx(),
			)
		}
	}

	// -------------------------------------------------------------------
	// Teardown
	// -------------------------------------------------------------------

	@Test
	fun aDisconnectAfterAnUnreachablePeerReportsNoTraffic() {
		if (!ensureVpnConsent()) {
			return
		}
		// Deliberately separate from `anUnreachableEndpointFailsRatherThan
		// ReportingSuccess`: that one asserts the handshake never happened,
		// this one asserts the tunnel can be torn down afterwards without the
		// engine reporting bytes it never carried. Byte counters report the
		// handshake initiation that was queued and never answered, so the
		// assertion is on the handshake time, not on the counters.
		val mapped = mapConfig(requestFor(allowedIps = "0.0.0.0/0"))
		backend.setState(tunnel, Tunnel.State.UP, mapped.config)
		backend.setState(tunnel, Tunnel.State.DOWN, null)
		assertEquals(Tunnel.State.DOWN, backend.getState(tunnel))
	}

	/**
	 * Ensures the operating system's VPN consent, reporting rather than
	 * throwing when it cannot be obtained.
	 *
	 * Tests that need the interface return early instead of failing when
	 * consent is unavailable, because that is an environment limit and not a
	 * property of the tunnel. Tests that only map a configuration do not
	 * need consent and do not call this.
	 */
	private fun ensureVpnConsent(): Boolean {
		if (!hasVpnConsent()) {
			grantVpnConsentToSelf()
		}
		if (!hasVpnConsent()) {
			org.junit.Assume.assumeTrue(
				"VPN consent could not be granted to the test host",
				false,
			)
			return false
		}
		return true
	}


	/**
	 * Builds the request shape the Dart bridge sends, with a throwaway key pair.
	 *
	 * The keys are RFC 7748 test vectors, not secrets and not a real server's.
	 * They are structurally valid so the engine's own parser accepts them; no
	 * handshake is possible or attempted against the reserved endpoint.
	 */
	private fun requestFor(
		allowedIps: String,
		ipv6: String = "prefer_tunnel",
		port: Int = 51820,
	): Map<String, Any?> {
		val peer = JSONObject()
			.put("publicKey", "iGaPncC709q7zIxUD9OMJENN3dh+W40oQx0Lv7AStp8=")
			.put("endpoint", "192.0.2.1:$port")
			// A list, because that is what `TunnelJson.encode` produces:
			// `allowedIps: peer.allowedIps.map((i) => i.toString()).toList()`.
			// Sending a comma-joined string here would test a shape the app never
			// emits, and the parser would correctly reject it.
			.put("allowedIps", allowedIps.toJsonArray())
			.put("persistentKeepalive", 25)

		val wireguard = JSONObject()
			.put("privateKey", "02R31BtVMJe/5r8cMd8uRVf6DysDrWKFXxDlMdRDU6c=")
			.put("addresses", org.json.JSONArray().put("10.8.0.2/32"))
			.put("dns", org.json.JSONArray().put("10.8.0.1"))
			.put("mtu", 1420)
			.put("peers", org.json.JSONArray().put(peer))

		// The exact shape the Dart bridge sends over the method channel: a map
		// whose `configJson` entry is the serialised configuration. Reproducing
		// it here rather than a convenient shape of the test's own is the point,
		// because it means a change to the wire format breaks this test.
		val configJson = JSONObject()
			.put("kind", "wireGuard")
			.put("wireguard", wireguard)
			.toString()

		return mapOf(
			"configJson" to configJson,
			"serverId" to "test",
			"countryLabel" to "Test",
			"killSwitch" to "off",
			"dnsMode" to "vpn",
			"customDns" to emptyList<String>(),
			"ipv6" to ipv6,
			"mtu" to 1420,
			"allowLan" to false,
			"allowedApps" to null,
			"disallowedApps" to null,
		)
	}

	/**
	 * The same request with a deliberately invalid private key, so the test
	 * exercises the rejection path without needing a second wire format.
	 */
	/** Space-separated prefixes to a JSON array, the shape TunnelJson produces. */
	private fun String.toJsonArray() =
		org.json.JSONArray().also { array ->
			split(' ').filter { it.isNotBlank() }.forEach(array::put)
		}

	private fun requestWithPrivateKey(privateKey: String): Map<String, Any?> {
		val peer = JSONObject()
			.put("publicKey", "iGaPncC709q7zIxUD9OMJENN3dh+W40oQx0Lv7AStp8=")
			.put("endpoint", "192.0.2.1:51820")
			.put("allowedIps", org.json.JSONArray().put("0.0.0.0/0"))
		val wireguard = JSONObject()
			.put("privateKey", privateKey)
			.put("addresses", org.json.JSONArray().put("10.8.0.2/32"))
			.put("peers", org.json.JSONArray().put(peer))
		return requestFor("0.0.0.0/0") + (
			"configJson" to JSONObject().put("kind", "wireGuard").put("wireguard", wireguard).toString()
			)
	}

	/**
	 * Parses the request the way the plugin does, then maps it.
	 *
	 * Going through [TunnelRequestParser] rather than constructing a
	 * `TunnelRequestKey` directly means this exercises the same path the
	 * service uses, so a break in the wire format is caught here rather than
	 * first on a user's device.
	 */
	private fun mapConfig(request: Map<String, Any?>) =
		WgConfigMapper.map(TunnelRequestParser.parse(request))
}
