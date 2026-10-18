package dev.phantrix.phantrix_platform

import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel

/**
 * The event channel Dart listens on for tunnel state.
 *
 * This build sends nothing: there is no engine on Android, so there is no
 * state to report. The channel is still registered because Dart subscribes to
 * it at startup, and a subscription with no handler is answered with an error
 * rather than with silence.
 */
internal class EventChannelListener(
	messenger: BinaryMessenger,
	name: String,
) : EventChannel.StreamHandler {

	private val channel = EventChannel(messenger, name)

	fun attach() {
		channel.setStreamHandler(this)
	}

	fun dispose() {
		channel.setStreamHandler(null)
	}

	override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
		// Nothing to replay and nothing to follow: the subscription stays
		// open, and a build with an engine would send on it from here.
	}

	override fun onCancel(arguments: Any?) {
		// Nothing is held, so there is nothing to release.
	}
}
