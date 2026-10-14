package dev.phantrix.phantrix_platform

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Build

/**
 * Android VPN permission handling.
 *
 * [VpnService.prepare] returns a non-null Intent when the user has never
 * granted permission, or revoked it. The plugin must start that intent and
 * only then start the service, which is why [preparationIntent] is separate
 * from [isPrepared].
 */
internal object VpnPermissions {

	const val REQUEST_CODE = 0x5647

	/** True when the tunnel may be established without asking the user. */
	fun isPrepared(context: Context): Boolean = VpnService.prepare(context) == null

	/**
	 * The consent intent, or null when permission is already granted.
	 */
	fun preparationIntent(context: Context): Intent? = VpnService.prepare(context)

	/**
	 * True when Android itself is currently blocking all traffic outside a VPN.
	 *
	 * This is the "Block connections without VPN" switch in the system VPN
	 * settings, combined with always-on VPN pointing at this app. It is the
	 * only genuine kill switch on stock Android: no application API can
	 * install a traffic-blocking rule that survives the tunnel interface, so
	 * anything the app claims beyond this would be fiction.
	 *
	 * Read from `Settings.Secure`, which any app may read for its own user:
	 * `always_on_vpn_app` names the package holding the always-on slot and
	 * `always_on_vpn_lockdown` is 1 when blocking is armed. Anything
	 * unreadable — an OEM that moved the keys, a restricted profile — answers
	 * false rather than throwing, because "unknown" must never be presented
	 * as "protected".
	 */
	fun isSystemLockdownActive(context: Context): Boolean {
		return try {
			val resolver = context.contentResolver
			val holder = android.provider.Settings.Secure.getString(
				resolver,
				"always_on_vpn_app",
			)
			if (holder != context.packageName) {
				return false
			}
			android.provider.Settings.Secure.getInt(
				resolver,
				"always_on_vpn_lockdown",
				0,
			) == 1
		} catch (error: Exception) {
			false
		}
	}

	/**
	 * Opens the system VPN settings screen.
	 *
	 * Android has no single "VPN settings" activity across OEMs, so the
	 * supported path is the network settings screen, which lists the app's
	 * VPN entry on every version that matters.
	 */
	fun openSettings(context: Context) {
		val intent = Intent("android.net.vpn.SETTINGS").apply {
			addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
		}
		try {
			context.startActivity(intent)
		} catch (error: Exception) {
			// Fall back to the app's own settings so the user is not stuck.
			intent.action = android.provider.Settings.ACTION_WIRELESS_SETTINGS
			try {
				context.startActivity(intent)
			} catch (second: Exception) {
				// Nothing more we can do; the UI says so.
			}
		}
	}

	/** The minimum API this plugin supports. */
	val minimumSdk: Int = Build.VERSION_CODES.LOLLIPOP
}
