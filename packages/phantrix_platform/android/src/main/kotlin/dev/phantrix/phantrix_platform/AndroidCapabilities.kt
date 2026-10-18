package dev.phantrix.phantrix_platform

import android.content.Context
import android.os.Build

/**
 * Reports what the Android platform can do.
 *
 * Every value here is a fact about the OS, not an intention: the UI reads this
 * and only offers switches the platform will actually honour.
 *
 * This build has no tunnel engine on Android, so [openVpn] is false and the
 * values below describe what the platform offers rather than a tunnel the app
 * can run. [bootStart] is the exception that is about this app rather than the
 * platform, and it is false because there is no boot path left to honour it.
 *
 * In particular, [killSwitch] is always false. No application API on stock
 * Android can install a traffic-blocking rule that survives the tunnel
 * interface going away — the gap between "tunnel down" and "reconnected" is
 * unprotected by anything the app controls. The protection that does exist is
 * the operating system's own Always-on VPN with "Block connections without
 * VPN", which the user enables in the system settings and which is reported
 * separately as [systemLockdown], read live from `Settings.Secure`. An app
 * that claimed its reconnect loop was a kill switch would be lying about the
 * one property users most need to be true.
 */
internal data class AndroidCapabilities(
	val platform: String,
	val killSwitch: Boolean,
	val ipv6Block: Boolean,
	val vpnDns: Boolean,
	val perApp: Boolean,
	val lanBypass: Boolean,
	val alwaysOn: Boolean,
	val tray: Boolean,
	val bootStart: Boolean,
	val systemLockdown: Boolean,
	/**
	 * Whether this build can start an OpenVPN tunnel. Always false on Android:
	 * no OpenVPN engine is bundled (see docs/LICENSING_AUDIT.md), so the Dart side
	 * never advertises one.
	 */
	val openVpn: Boolean,
	val limitations: Map<String, String>,
) {

	companion object {
		fun of(context: Context): AndroidCapabilities {
			val api = Build.VERSION.SDK_INT
			val limitations = mutableMapOf<String, String>()
			if (api < Build.VERSION_CODES.Q) {
				limitations["perApp"] =
					"Per-app split tunnelling needs Android 10 or newer."
			}
			// Unconditional: no API level changes the fact that the app cannot
			// block traffic itself. `minSdk` is 24, so there is no older
			// platform to special-case here.
			//
			// One line, deliberately: this text is shown on the home screen,
			// where a paragraph would be clutter. The full explanation lives
			// in Settings next to the control it qualifies.
			limitations["kill_switch"] =
				"Phantrix cannot block traffic itself if the tunnel drops; " +
					"Settings shows the system protection that exists."

			return AndroidCapabilities(
				platform = "android-$api",
				killSwitch = false,
				ipv6Block = true,
				vpnDns = true,
				perApp = api >= Build.VERSION_CODES.Q,
				lanBypass = true,
				alwaysOn = true,
				tray = false,
				// No boot receiver and no service to start: the app cannot
				// come up tunnelling, so the setting that asks it to must be
				// reported as unsupported rather than offered and ignored.
				bootStart = false,
				systemLockdown = isSystemLockdownActive(context),
				openVpn = false,
				limitations = limitations,
			)
		}

		private fun isSystemLockdownActive(context: Context): Boolean =
			VpnSettings.isSystemLockdownActive(context)
	}
}
