package dev.phantrix.phantrix_platform

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/**
 * The Flutter-facing side of the Android tunnel.
 *
 * Responsibilities:
 *  * report capabilities so the UI only offers what Android really supports;
 *  * request VpnService permission and translate the answer into a boolean
 *    the Dart side can act on, including a revocation;
 *  * stage a validated request and start the foreground service;
 *  * stop the service and always clean up;
 *  * forward service state changes to Dart over the event channel.
 *
 * The plugin holds no tunnel logic of its own. That lives in
 * [PhantrixTunnelService] for WireGuard — which survives the activity being
 * destroyed, which is the only way a VPN keeps working when the user swipes the
 * app away. Android has no OpenVPN engine in this build: OpenVPN requests are
 * refused with an explicit error rather than silently ignored.
 */
class PhantrixPlugin :
	FlutterPlugin,
	ActivityAware,
	MethodChannel.MethodCallHandler,
	PluginRegistry.ActivityResultListener,
	PhantrixTunnelService.TunnelListener {

	private lateinit var methodChannel: MethodChannel
	private var events: EventChannelListener? = null
	private var activity: Activity? = null
	private var applicationContext: Context? = null
	private var pendingPermission: MethodChannel.Result? = null

	override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
		methodChannel = MethodChannel(binding.binaryMessenger, CHANNEL)
		methodChannel.setMethodCallHandler(this)

		applicationContext = binding.applicationContext
		events = EventChannelListener(binding.binaryMessenger, EVENT_CHANNEL).also {
			it.attach()
		}
		PhantrixTunnelService.listener = this
	}

	override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
		methodChannel.setMethodCallHandler(null)
		events?.dispose()
		events = null
		if (PhantrixTunnelService.listener === this) {
			PhantrixTunnelService.listener = null
		}
	}

	override fun onAttachedToActivity(binding: ActivityPluginBinding) {
		activity = binding.activity
		binding.addActivityResultListener(this)
	}

	override fun onDetachedFromActivityForConfigChanges() = clearActivity()

	override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
		activity = binding.activity
		binding.addActivityResultListener(this)
	}

	override fun onDetachedFromActivity() = clearActivity()

	private fun clearActivity() {
		activity = null
		pendingPermission?.success(false)
		pendingPermission = null
	}

	override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
		val context = activity ?: run {
			result.error(
				"platform.missing",
				"No activity is attached, so this call cannot be served.",
				null,
			)
			return
		}
		when (call.method) {
			"capabilities" -> result.success(capabilityMap(context))

			"requestPermission" -> requestPermission(context, result)

			"startTunnel" -> startTunnel(context, call, result)

			"stopTunnel" -> {
				stopEveryTunnel(context)
				result.success(null)
			}

			"openVpnSettings" -> {
				VpnPermissions.openSettings(context)
				result.success(null)
			}

			// The app's private files directory. `filesDir` is inside the
			// sandbox, so a configuration written there is readable only by
			// this application and is removed with it on uninstall. A public
			// directory would let any other app read a private key.
			"appDataDirectory" -> result.success(context.filesDir.absolutePath)

			// The Dart state machine decides what "verified" means. This call
			// exists so the native side can log the same moment, and so a future
			// engine can arm its own kill switch on it.
			"reportVerification" -> result.success(null)

			// Read live on every call, never cached: the user can flip this
			// switch in the system settings while the app runs, and a cached
			// answer would report protection that is no longer there — or hide
			// protection that now is.
			"systemLockdown" ->
				result.success(VpnPermissions.isSystemLockdownActive(context))

			else -> result.notImplemented()
		}
	}

	private fun capabilityMap(context: Context): Map<String, Any?> {
		val caps = AndroidCapabilities.of(context)
		return mapOf(
			"platform" to caps.platform,
			"killSwitch" to caps.killSwitch,
			"ipv6Block" to caps.ipv6Block,
			"vpnDns" to caps.vpnDns,
			"perApp" to caps.perApp,
			"lanBypass" to caps.lanBypass,
			"alwaysOn" to caps.alwaysOn,
			"tray" to caps.tray,
			"bootStart" to caps.bootStart,
			"openVpn" to caps.openVpn,
			"systemLockdown" to caps.systemLockdown,
			"limitations" to caps.limitations,
		)
	}

	private fun requestPermission(context: Context, result: MethodChannel.Result) {
		if (VpnPermissions.isPrepared(context)) {
			result.success(true)
			return
		}
		val intent = VpnPermissions.preparationIntent(context)
		if (intent == null) {
			result.success(true)
			return
		}
		// Only one request may be outstanding, otherwise a second call would
		// silently drop its result.
		if (pendingPermission != null) {
			result.success(false)
			return
		}
		pendingPermission = result
		try {
			activity?.startActivityForResult(intent, VpnPermissions.REQUEST_CODE)
		} catch (error: Exception) {
			pendingPermission = null
			result.success(false)
		}
	}

	/**
	 * Stops whichever tunnel is running, and then stops the other one's service
	 * too, so a stale component can never be left holding a profile.
	 *
	 * Only one `VpnService` can be active per device. A stop that left the other
	 * protocol's service alive would be a service the next `startTunnel` has to
	 * override blindly, and one that a system restart could resurrect — the
	 * always-on and crash-recovery paths both read a persisted profile. Stopping
	 * both outright is what makes "exactly one tunnel" a property of the code
	 * rather than of whoever pressed the button.
	 */
	private fun stopEveryTunnel(context: Context) {
		try {
			// Stopping the service runs `onDestroy` → `stopTunnel`, which is what
			// brings the Go engine's TUN down. Without it the backend would keep
			// global native state alive for a tunnel the user just closed.
			context.stopService(Intent(context, PhantrixTunnelService::class.java))
		} catch (error: Exception) {
			Log.w(TAG, "The WireGuard service could not be stopped: ${error.javaClass.simpleName}")
		}
		PendingRequest.clear()
	}

	private fun startTunnel(context: Context, call: MethodCall, result: MethodChannel.Result) {
		if (!VpnPermissions.isPrepared(context)) {
			result.error(
				"permission.denied",
				"VpnService permission has not been granted.",
				null,
			)
			return
		}
		val request = try {
			TunnelRequestParser.parse(call.arguments)
		} catch (error: TunnelRequestException) {
			// The message is a reason, never the payload.
			result.error(error.code, error.message, null)
			return
		} catch (error: IllegalArgumentException) {
			result.error("wg.config_invalid", error.message, null)
			return
		}

		// Android has no OpenVPN engine in this build (see docs/LICENSING_AUDIT.md).
		// Refuse explicitly so Dart reports the real reason instead of hanging.
		if (request.isOpenVpn) {
			result.error(
				"ovpn.unsupported",
				"OpenVPN is not available on Android in this build. Use a WireGuard configuration.",
				null,
			)
			return
		}

		val strict = RoutingPolicy.killSwitchStatus(request)
		if (strict == "unsupported") {
			// Reported rather than silently downgraded.
			events?.send(
				mapOf(
					"state" to "preparing",
					"message" to
						"Android cannot enforce a strict kill switch. The tunnel will " +
							"still stop when the service is revoked.",
					"traffic" to mapOf("rx" to 0L, "tx" to 0L),
				),
			)
		}

		PendingRequest.current = request

		val intent = Intent(context, PhantrixTunnelService::class.java).apply {
			action = PhantrixTunnelService.ACTION_CONNECT
		}
		if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
			context.startForegroundService(intent)
		} else {
			context.startService(intent)
		}
		result.success(null)
	}

	override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
		if (requestCode != VpnPermissions.REQUEST_CODE) {
			return false
		}
		val pending = pendingPermission
		pendingPermission = null
		pending?.success(resultCode == Activity.RESULT_OK)
		return true
	}

	override fun onState(state: String, message: String?) {
		// The activity is only used to build the capability map, and the
		// tunnel service outlives the activity (notification Stop, process
		// recreation, backgrounding). Dropping those events would leave Dart
		// showing a stale state, so the application context serves when the
		// activity cannot.
		val context = activity ?: applicationContext ?: return
		events?.send(
			mapOf(
				"state" to state,
				"message" to message,
				"capabilities" to capabilityMap(context),
			),
		)
	}

	override fun onFailure(code: String, message: String?) {
		events?.send(
			mapOf(
				"state" to "failed",
				"errorCode" to code,
				"message" to message,
			),
		)
	}

	override fun onRevocation(message: String?) {
		// Deliberately does not require an activity. A revocation is the one state
		// change that can arrive while the app's UI is already gone — the user
		// swiped the app away, another VPN took over — and gating it on an
		// activity would drop exactly the event that stops the next launch from
		// showing "Connected".
		//
		// One event carrying both the state and the code. Dart reacts to the code,
		// and the state is there so anything reading the stream directly is not
		// told a revocation was a failure.
		events?.send(
			mapOf(
				"state" to "revoked",
				"errorCode" to "permission.revoked",
				"message" to message,
			),
		)
	}

	override fun onStatistics(
		state: String,
		rxBytes: Long,
		txBytes: Long,
		lastHandshakeAtMillis: Long?,
	) {
		events?.send(
			mapOf(
				"state" to state,
				// Real counters read from the engine that owns the tunnel — the Go
				// backend's statistics for WireGuard, the engine's byte-count
				// listener for OpenVPN. Never estimates, because an estimate is a
				// claim about traffic nobody measured.
				"traffic" to mapOf("rx" to rxBytes, "tx" to txBytes),
				// Null rather than 0 when no handshake has happened. Dart uses
				// the difference to decide whether "connected" may be claimed,
				// and a zero would be indistinguishable from a stale reading.
				"lastHandshakeAtMillis" to lastHandshakeAtMillis,
			),
		)
	}

	companion object {
		private const val TAG = "PhantrixPlugin"
		private const val CHANNEL = "dev.phantrix.phantrix/tunnel"
		private const val EVENT_CHANNEL = "dev.phantrix.phantrix/tunnelEvents"
	}
}
