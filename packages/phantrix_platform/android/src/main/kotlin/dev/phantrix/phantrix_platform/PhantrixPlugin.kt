package dev.phantrix.phantrix_platform

import android.app.Activity
import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * The Flutter-facing side of the Android platform bridge.
 *
 * This build has no tunnel engine on Android. The app is an OpenVPN client,
 * and no OpenVPN engine is bundled here (see docs/LICENSING_AUDIT.md), so this
 * plugin reports capabilities, answers a start request with the reason it
 * cannot run, and owns the app's private directory. Nothing here claims a
 * tunnel.
 *
 * Responsibilities:
 *  * report capabilities so the UI only offers what Android really supports;
 *  * refuse a tunnel request explicitly, so Dart shows the real reason instead
 *    of waiting for a state change that can never arrive;
 *  * report the operating system's own lockdown state, read live;
 *  * keep the event channel open, because Dart subscribes to it at startup.
 */
class PhantrixPlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler {

	private lateinit var methodChannel: MethodChannel
	private var events: EventChannelListener? = null
	private var activity: Activity? = null

	override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
		methodChannel = MethodChannel(binding.binaryMessenger, CHANNEL)
		methodChannel.setMethodCallHandler(this)

		// Opened even though nothing is ever sent on it. Dart subscribes at
		// startup, and an event channel with no handler answers that
		// subscription with an error rather than staying silent.
		events = EventChannelListener(binding.binaryMessenger, EVENT_CHANNEL).also {
			it.attach()
		}
	}

	override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
		methodChannel.setMethodCallHandler(null)
		events?.dispose()
		events = null
	}

	override fun onAttachedToActivity(binding: ActivityPluginBinding) {
		activity = binding.activity
	}

	override fun onDetachedFromActivityForConfigChanges() = clearActivity()

	override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
		activity = binding.activity
	}

	override fun onDetachedFromActivity() = clearActivity()

	private fun clearActivity() {
		activity = null
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

			// There is no consent dialog to raise: the only permission this
			// platform has is for a tunnel engine, and this build has none.
			// `true` answers "nothing stands in the way", and the start call
			// below is what gives the real reason.
			"requestPermission" -> result.success(true)

			"startTunnel" -> result.error(
				"backend.not_installed",
				"This build has no tunnel engine for Android, so no tunnel can " +
					"be started. OpenVPN runs on Windows only.",
				null,
			)

			"stopTunnel" -> result.success(null)

			"openVpnSettings" -> {
				VpnSettings.openSettings(context)
				result.success(null)
			}

			// The app's private files directory. `filesDir` is inside the
			// sandbox, so anything written there is readable only by this
			// application and is removed with it on uninstall. A public
			// directory would let any other app read what the app stored.
			"appDataDirectory" -> result.success(context.filesDir.absolutePath)

			// The Dart state machine decides what "verified" means, and no
			// platform handshake is needed for it: verification is an app-side
			// fact, so there is no method-call round trip for it.

			// Read live on every call, never cached: the user can flip this
			// switch in the system settings while the app runs, and a cached
			// answer would report protection that is no longer there — or hide
			// protection that now is.
			"systemLockdown" ->
				result.success(VpnSettings.isSystemLockdownActive(context))

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

	companion object {
		private const val CHANNEL = "dev.phantrix.phantrix/tunnel"
		private const val EVENT_CHANNEL = "dev.phantrix.phantrix/tunnelEvents"
	}
}
