package dev.phantrix.phantrix_platform

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel

/**
 * Pushes service state to Dart.
 *
 * A single instance is shared by the plugin and the service, because the
 * service outlives the activity and the activity is what owns the messenger.
 */
internal class EventChannelListener(
	messenger: BinaryMessenger,
	private val name: String,
) : EventChannel.StreamHandler {

	private val channel = EventChannel(messenger, name)
	private var eventSink: EventChannel.EventSink? = null

	fun attach() {
		channel.setStreamHandler(this)
	}

	fun dispose() {
		channel.setStreamHandler(null)
		eventSink = null
	}

	fun send(payload: Map<String, Any?>) {
		// Flutter's platform channels may only be written from the main
		// thread. Every engine callback — the WireGuard Go backend's
		// `onStateChange` — arrives on a background thread, and calling
		// `EventSink.success` there crashes the process with
		// "Methods marked with @UiThread must be executed on the main
		// thread". The live run found this; it is marshalled here so every
		// caller is safe by construction rather than by remembering.
		val sink = eventSink ?: return
		val message = Runnable { sink.success(payload) }
		if (Looper.myLooper() == Looper.getMainLooper()) {
			message.run()
		} else {
			mainHandler.post(message)
		}
	}

	private val mainHandler = Handler(Looper.getMainLooper())

	override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
		eventSink = events
		// Replay the current state so a late subscriber is not left showing a
		// stale "disconnected" while a tunnel is already up.
		pending?.let { message ->
			events?.success(message)
		}
	}

	override fun onCancel(arguments: Any?) {
		eventSink = null
		pending = null
	}

	private companion object {
		@Volatile
		var pending: Map<String, Any?>? = null
	}
}
