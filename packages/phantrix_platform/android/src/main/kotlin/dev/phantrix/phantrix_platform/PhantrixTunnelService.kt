package dev.phantrix.phantrix_platform

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Log
import com.wireguard.android.backend.Backend
import com.wireguard.android.backend.GoBackend
import com.wireguard.android.backend.Statistics
import com.wireguard.android.backend.Tunnel
import com.wireguard.android.util.SharedLibraryLoader
import com.wireguard.crypto.Key
import java.util.concurrent.atomic.AtomicBoolean

/**
 * The real Android WireGuard tunnel.
 *
 * The cryptography, the Noise_IK handshake and the packet routing all happen
 * inside the official WireGuard userspace engine
 * (`com.wireguard.android:tunnel`, Apache-2.0), which runs as
 * `libwg-go.so`. Phantrix does not implement any of that and must never do
 * so: reimplementing WireGuard would be exactly the kind of custom
 * cryptography this project refuses to ship.
 *
 * This class is the *lifecycle* half. It owns:
 *
 *  * the user-consent [VpnService] the operating system granted;
 *  * the mandatory foreground notification;
 *  * the translation between Dart's connection requests and the backend's
 *    `Tunnel.State`;
 *  * the verification step that decides whether "connected" may be reported.
 *
 * The TUN interface itself is established by the backend's own inner
 * `VpnService`, declared in the library's manifest and merged into ours. Only
 * one VPN interface can exist on a device, so this service must never also
 * call [VpnService.Builder.establish]; doing both would silently drop one of
 * them.
 *
 * ### What "connected" means here, precisely
 *
 * Three different things are tracked separately and never collapsed into one
 * flag:
 *
 *  * **configured** — the engine accepted the configuration and brought the
 *    interface up. `GoBackend.getState` returning [Tunnel.State.UP].
 *  * **handshaked** — the engine has completed a Noise_IK handshake with the
 *    peer and observed recent traffic. Derived from
 *    `Statistics.peer(key).latestHandshakeEpochMillis` together with the byte
 *    counters.
 *  * **verified** — the whole app's contract: a handshake has been seen
 *    recently *and* the independent leak probe has confirmed the exit address
 *    changed. That second half is decided in Dart, not here, because it needs
 *    the address observed before the tunnel came up.
 *
 * A handshake proves the peer is real and the crypto works. It does **not**
 * prove every application on the device is routed through the tunnel, so this
 * class never claims more than it can see.
 */
class PhantrixTunnelService : VpnService(), Tunnel {

	companion object {
		const val ACTION_CONNECT = "dev.phantrix.phantrix.CONNECT"
		const val ACTION_DISCONNECT = "dev.phantrix.phantrix.DISCONNECT"

		private const val CHANNEL_ID = "phantrix_tunnel"
		private const val NOTIFICATION_ID = 4711
		private const val TAG = "PhantrixTunnel"

		/** The single backend instance; the Go engine holds global native state. */
		@Volatile
		private var backendInstance: Backend? = null

		/**
		 * How recently a handshake must have happened for the tunnel to be
		 * considered working.
		 *
		 * WireGuard rekeys every two minutes and sends a keepalive at most that
		 * often. Three minutes allows for one missed exchange plus scheduling
		 * delay, so a healthy tunnel is never reported as dead.
		 */
		private const val HANDSHAKE_FRESHNESS_MS = 3 * 60 * 1000L

		/** A single tunnel, so the name is fixed rather than per-server. */
		private const val NAME = "phantrix"

		/** How often engine statistics are read. */
		private const val POLL_INTERVAL_MS = 1000L

		/**
		 * The plugin instance that forwards engine events to Dart.
		 *
		 * Static because the service and the plugin are different objects with
		 * independent lifetimes: the service outlives the Flutter engine (a
		 * tunnel must survive the activity being destroyed), and the plugin is
		 * recreated whenever the engine is. `@Volatile` because the service
		 * reads it from the main looper while the plugin writes it from the
		 * engine thread.
		 */
		@Volatile
		@JvmStatic
		var listener: TunnelListener? = null

		/**
		 * Publishes an engine event to whoever is listening.
		 *
		 * All engine state changes funnel through here rather than touching
		 * [listener] directly, so there is exactly one place where a null
		 * listener — the service outliving the Flutter engine — is handled.
		 */
		@JvmStatic
		fun emit(state: String, message: String?) {
			listener?.onState(state, message)
		}

		@JvmStatic
		fun emitFailure(code: String, message: String?) {
			listener?.onFailure(code, message)
		}

		@JvmStatic
		fun emitStatistics(
			state: String,
			rxBytes: Long,
			txBytes: Long,
			lastHandshakeAtMillis: Long?,
		) {
			listener?.onStatistics(state, rxBytes, txBytes, lastHandshakeAtMillis)
		}

		/**
		 * Reports that the operating system withdrew VPN consent.
		 *
		 * Separate from [emitFailure] because revocation is not a failure of the
		 * tunnel: the configuration and the engine were fine, and the operating
		 * system simply took the permission away. Dart's state machine can tell
		 * "your credentials are wrong" and "Android stopped you" apart only if the
		 * two arrive as different answers, and the second one carries the
		 * `permission.revoked` code the UI is supposed to react to.
		 */
		@JvmStatic
		fun emitRevocation(message: String?) {
			listener?.onRevocation(message)
		}
	}

	/** Callbacks into the plugin, which forwards to Dart over the event channel. */
	interface TunnelListener {
		fun onState(state: String, message: String?)

		fun onFailure(code: String, message: String?)

		/** The OS withdrew VPN consent, or another VPN took the slot away. */
		fun onRevocation(message: String?)

		/** Reports real engine statistics: bytes and handshake freshness. */
		fun onStatistics(
			state: String,
			rxBytes: Long,
			txBytes: Long,
			lastHandshakeAtMillis: Long?,
		)
	}

	private val running = AtomicBoolean(false)
	private var descriptor: ParcelFileDescriptor? = null
	private var mapped: WgConfigMapper.Mapped? = null
	private var pollHandler: android.os.Handler? = null
	private var latestState: String = "disconnected"

	// ---------------------------------------------------------------- backend

	/**
	 * The official engine, created once.
	 *
	 * `libwg-go.so` must be loaded before the backend is constructed, because
	 * its constructor reaches native code. The load is idempotent and cheap, so
	 * it is repeated harmlessly on reconnect.
	 */
	private fun backend(): Backend {
		backendInstance?.let { return it }
		synchronized(this) {
			backendInstance?.let { return it }
			try {
				SharedLibraryLoader.loadSharedLibrary(applicationContext, "wg-go")
			} catch (error: Exception) {
				// Almost always an ABI mismatch: the APK was built without this
				// device's native library. That is a packaging fault, not a user
				// error, so it is reported as one.
				throw TunnelStartException(
					"backend.unavailable",
					"This build of Phantrix does not include a WireGuard engine for " +
						"this device's processor.",
				)
			}
			val created = GoBackend(applicationContext)
			backendInstance = created
			return created
		}
	}

	// -------------------------------------------------------------- lifecycle

	override fun onCreate() {
		super.onCreate()
		createChannel()
	}

	override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
		when (intent?.action) {
			ACTION_CONNECT -> handleConnect()
			ACTION_DISCONNECT -> {
				stopTunnel()
				stopSelf()
			}

			else -> {
				// A restart with no action means the process was recreated. The
				// staged request is gone with it, so there is nothing to resume
				// and pretending otherwise would show a dead tunnel as live.
				Log.i(TAG, "Service restarted without a connection request; stopping.")
				stopTunnel()
				stopSelf()
				return START_NOT_STICKY
			}
		}
		// Not sticky: a VPN tunnel must be re-established deliberately, with a
		// configuration and with the user's consent still valid. The system
		// restarting us in the background with no request would be worse than
		// reporting a disconnected state.
		return START_NOT_STICKY
	}

	private fun handleConnect() {
		if (!running.compareAndSet(false, true)) {
			// A duplicate request must not create a second interface. Android
			// would only grant one, and the attempt would look like a failure.
			Log.i(TAG, "A connect request arrived while the tunnel is already starting.")
			publish("connecting", null)
			return
		}

		val request = PendingRequest.current
		if (request == null) {
			running.set(false)
			reportFailure(
				"request.missing",
				"The tunnel was asked to start without a configuration. " +
					"Reconnect from the app.",
			)
			stopSelf()
			return
		}

		publish("preparing", null)
		startForegroundCompat()

		// The staged request is dropped from the holder as soon as it has been
		// read, so the private key is not left in a static field after the
		// engine has its own copy.
		PendingRequest.clear()

		try {
			val engine = backend()
			val built = WgConfigMapper.map(request)
			mapped = built

			engine.setState(this, Tunnel.State.UP, built.config)

			val state = engine.getState(this)
			if (state != Tunnel.State.UP) {
				// The engine refused or failed to raise the interface. Report
				// that as a failure rather than waiting for a state that will
				// never arrive.
				tearDownEngine(engine)
				reportFailure(
					"tunnel.not_up",
					"WireGuard could not bring the tunnel up. The server may be " +
						"unreachable or the configuration may be rejected.",
				)
				stopSelf()
				return
			}

			publish("established", null)
			startStatisticsPolling(engine, built.primaryPeerKey)
		} catch (error: TunnelStartException) {
			tearDownEngineSafely()
			reportFailure(error.code, error.message)
			stopSelf()
		} catch (error: WgMappingException) {
			tearDownEngineSafely()
			reportFailure(error.code, error.message)
			stopSelf()
		} catch (error: Exception) {
			// The Go engine signals a handshake or routing failure by throwing.
			// The class name is logged; the message can carry configuration
			// detail, so it is not.
			Log.e(TAG, "The WireGuard engine failed: ${error.javaClass.simpleName}")
			tearDownEngineSafely()
			reportFailure(
				"tunnel.failed",
				"The WireGuard engine could not start the tunnel. This is usually " +
					"a server that is unreachable or rejecting this configuration.",
			)
			stopSelf()
		}
	}

	private fun tearDownEngine(engine: Backend) {
		try {
			engine.setState(this, Tunnel.State.DOWN, null)
		} catch (error: Exception) {
			Log.w(TAG, "Turning the tunnel down failed: ${error.javaClass.simpleName}")
		}
	}

	private fun tearDownEngineSafely() {
		mapped = null
		try {
			backendInstance?.setState(this, Tunnel.State.DOWN, null)
		} catch (error: Exception) {
			Log.w(TAG, "Turning the tunnel down failed: ${error.javaClass.simpleName}")
		}
		stopStatisticsPolling()
		running.set(false)
	}

	/**
	 * Stops the tunnel for real: the engine first, then the service.
	 *
	 * Order matters. Bringing the interface down releases the TUN descriptor and
	 * the system removes the VPN; only then is it safe to tear the service
	 * down, or the interface can outlive the process that owns it.
	 */
	fun stopTunnel() {
		if (!running.get() && latestState == "disconnected") {
			return
		}
		tearDownEngineSafely()
		publish("disconnected", null)
	}

	override fun onRevoke() {
		// The user revoked VPN permission, or another VPN took over. The
		// interface is already gone; tear down the engine and tell Dart, so the
		// UI cannot keep showing "Connected".
		Log.i(TAG, "VPN permission was revoked.")
		tearDownEngineSafely()
		latestState = "revoked"
		// Reported once, through the revocation path, which carries both the state
		// and the `permission.revoked` code in a single event. Emitting a state
		// change and a failure separately would tell Dart the tunnel was revoked
		// twice, and the first of them could be dropped if the activity is gone.
		emitRevocation("VPN permission was withdrawn, so the tunnel stopped.")
		super.onRevoke()
		stopSelf()
	}

	override fun onDestroy() {
		// The service is going away, so its foreground notification goes with it.
		// Doing it explicitly rather than relying on the system means the shutdown
		// order — tunnel down, then notification gone — is one this class controls,
		// and a stop that throws on the way out cannot leave a stale notification
		// advertising a tunnel that is no longer running.
		if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
			stopForeground(STOP_FOREGROUND_REMOVE)
		}
		stopTunnel()
		super.onDestroy()
	}

	// ------------------------------------------------------------- monitoring

	/**
	 * Polls the engine for real statistics.
	 *
	 * This is what makes the reported state honest: instead of assuming the
	 * tunnel works because it started, the app watches byte counters and the
	 * last handshake time and reports "connecting" until a handshake has
	 * actually been observed.
	 */
	private fun startStatisticsPolling(engine: Backend, peerKey: Key?) {
		stopStatisticsPolling()
		val handler = android.os.Handler(android.os.Looper.getMainLooper())
		pollHandler = handler

		val task = object : Runnable {
			override fun run() {
				if (!running.get()) {
					return
				}
				try {
					val stats: Statistics? = engine.getStatistics(this@PhantrixTunnelService)
					if (stats == null || stats.isStale) {
						// No current data at all: the engine is not reporting
						// traffic, so the tunnel is not carrying anything yet.
						publish("connecting", null)
					} else {
						val peer = peerKey?.let { stats.peer(it) }
						publish("established", null)
						emitStatistics(
							state = stateLabel(stats, peer?.latestHandshakeEpochMillis ?: 0L),
							rxBytes = stats.totalRx(),
							txBytes = stats.totalTx(),
							lastHandshakeAtMillis = peer?.latestHandshakeEpochMillis
								?.takeIf { it > 0L },
						)
					}
				} catch (error: Exception) {
					Log.w(TAG, "Reading statistics failed: ${error.javaClass.simpleName}")
					publish("connecting", null)
				}
				handler.postDelayed(this, POLL_INTERVAL_MS)
			}
		}
		handler.post(task)
	}

	private fun stopStatisticsPolling() {
		pollHandler?.removeCallbacksAndMessages(null)
		pollHandler = null
	}

	/**
	 * Whether the engine has completed a handshake recently.
	 *
	 * A tunnel with an interface up but no handshake is carrying nothing. It is
	 * reported as still connecting, because from the user's point of view it is.
	 */
	private fun stateLabel(stats: Statistics, handshakeMillis: Long): String {
		if (handshakeMillis <= 0L) {
			return "connecting"
		}
		val age = System.currentTimeMillis() - handshakeMillis
		return if (age <= HANDSHAKE_FRESHNESS_MS) "handshaked" else "connecting"
	}

	/** True when the engine has a fresh handshake. Exposed for the leak check. */
	fun hasFreshHandshake(nowMillis: Long = System.currentTimeMillis()): Boolean {
		val stats = try {
			backendInstance?.getStatistics(this) ?: return false
		} catch (error: Exception) {
			return false
		}
		val key = mapped?.primaryPeerKey ?: return false
		val handshake = stats.peer(key)?.latestHandshakeEpochMillis ?: return false
		return handshake > 0L && (nowMillis - handshake) <= HANDSHAKE_FRESHNESS_MS
	}

	// ---------------------------------------------------------------- helpers

	private fun publish(state: String, message: String?) {
		latestState = state
		emit(state, message)
	}

	private fun reportFailure(code: String, message: String) {
		latestState = "failed"
		emitFailure(code, message)
	}

	private fun createChannel() {
		if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
			return
		}
		val manager = getSystemService(NotificationManager::class.java) ?: return
		if (manager.getNotificationChannel(CHANNEL_ID) != null) {
			return
		}
		val channel = NotificationChannel(
			CHANNEL_ID,
			"VPN connection",
			NotificationManager.IMPORTANCE_LOW,
		).apply {
			description = "Shown while Phantrix is carrying your traffic."
			setShowBadge(false)
		}
		manager.createNotificationChannel(channel)
	}

	/**
	 * The mandatory foreground notification.
	 *
	 * Resolves the app's own launcher activity rather than hard-coding an
	 * Activity class: the host app owns that, not this plugin.
	 */
	private fun startForegroundCompat() {
		val label = PendingRequest.current?.countryLabel?.takeIf { it.isNotBlank() }
			?: "connecting"
		// Resolve the launch intent before building the PendingIntent: passing a
		// null Intent would crash the platform.
		val launch = packageManager.getLaunchIntentForPackage(packageName)
		val contentIntent = launch?.let {
			PendingIntent.getActivity(
				this,
				0,
				it.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
				PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
			)
		}

		val builder = Notification.Builder(this, CHANNEL_ID)
			.setContentTitle("Phantrix")
			.setContentText("Connected to $label")
			.setSmallIcon(android.R.drawable.ic_lock_lock)
			.setOngoing(true)
			.setCategory(Notification.CATEGORY_SERVICE)
			.setPriority(Notification.PRIORITY_LOW)
		if (contentIntent != null) {
			builder.setContentIntent(contentIntent)
		}

		val notification = builder.build()
		if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
			// Android 14+ requires the foreground service type to be declared at
			// start time and to match the manifest. The plugin manifest declares
			// both FOREGROUND_SERVICE_SPECIAL_USE and foregroundServiceType.
			startForeground(
				NOTIFICATION_ID,
				notification,
				ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
			)
		} else {
			startForeground(NOTIFICATION_ID, notification)
		}
	}

	// ------------------------------------------------- Tunnel implementation

	override fun getName(): String = NAME

	override fun onStateChange(state: Tunnel.State?) {
		// Called by the engine when the state changes underneath us, for
		// example when the interface is torn down by the system.
		when (state) {
			Tunnel.State.UP -> publish("established", null)
			Tunnel.State.DOWN -> {
				if (running.get()) {
					tearDownEngineSafely()
					publish("disconnected", "The tunnel was stopped by the system.")
				}
			}

			Tunnel.State.TOGGLE -> publish("connecting", null)
			null -> Unit
		}
	}

}

/** A failure the user can act on, with a code Dart understands. */
internal class TunnelStartException(
	val code: String,
	override val message: String,
) : Exception(message)
