// The Flutter plugin bridge for Apple platforms.
//
// This is the Swift counterpart of the Android
// `PhantrixPlugin.kt` and the Windows C++ plugin. It
// registers the method and event channels the Dart
// layer already speaks, and forwards every call to
// `PhantrixVPNManager`. It contains no tunnel logic of
// its own: the WireGuard engine is WireGuardKit's, the
// configuration mapping is `PhantrixConfigMapper`'s, and
// the lifecycle is the manager's.
//
// ## Why the channel names are hard-coded
//
// They are a contract with the Dart layer in
// `packages/phantrix_platform/lib/phantrix_platform.dart`,
// which is shared by every platform. Changing a name
// here silently breaks every Apple build, so the names
// are asserted against the Dart constants in tests.

import Flutter
import Foundation
import NetworkExtension

#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

public class PhantrixPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
	private let manager = PhantrixVPNManager()
	private var eventSink: FlutterEventSink?
	private var statsTimer: Timer?
	private var lastStats: (rx: Int64, tx: Int64, handshakeMillis: Int64?) = (0, 0, nil)

	public static func register(with registrar: FlutterPluginRegistrar) {
		let channel = FlutterMethodChannel(
			name: "dev.phantrix.phantrix/tunnel",
			binaryMessenger: registrar.messenger(),
		)
		let instance = PhantrixPlugin()
		registrar.addMethodCallDelegate(instance, channel: channel)

		let events = FlutterEventChannel(
			name: "dev.phantrix.phantrix/tunnelEvents",
			binaryMessenger: registrar.messenger(),
		)
		events.setStreamHandler(instance)
	}

	// MARK: - FlutterStreamHandler

	public func onListen(
		withArguments arguments: Any?,
		eventSink events: @escaping FlutterEventSink
	) -> FlutterError? {
		eventSink = events
		manager.observe(
			onState: { [weak self] state in
				self?.publishState(state)
			},
			onError: { [weak self] error in
				self?.publishFailure(error)
			},
		)
		// The operating system reports the tunnel's status, but
		// not the engine's handshake time. That time is what
		// decides whether "connected" may be claimed at all, so
		// it is polled from the engine rather than assumed.
		startStatsPolling()
		publishState(manager.state)
		return nil
	}

	public func onCancel(withArguments arguments: Any?) -> FlutterError? {
		stopStatsPolling()
		eventSink = nil
		return nil
	}

	// MARK: - Method calls

	public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
		switch call.method {
		case "capabilities":
			result(capabilities())
		case "requestPermission":
			requestPermission(result)
		case "startTunnel":
			startTunnel(call.arguments, result)
		case "stopTunnel":
			stopTunnel(result)
		case "openVpnSettings":
			openVpnSettings(result)
		case "reportVerification":
			// The Dart state machine already recorded the
			// verification. There is nothing for the native
			// side to do, and inventing a side effect would
			// be a lie about what happened.
			result(nil)
		case "appDataDirectory":
			// The Application Support directory, which is the
			// correct place for user data that is not a
			// preference the user edits by hand. It is inside
			// the app's own container, so a configuration with
			// a private key in it is unreadable by any other app.
			// On macOS the app is sandboxed, so this location is
			// already confined by the sandbox profile.
			do {
				let fm = FileManager.default
				let base = try? fm.url(
					for: .applicationSupportDirectory,
					in: .userDomainMask,
					appropriateFor: nil,
					create: true
				)
				guard let base else {
					result(FlutterError(
						code: "app_directory",
						message: "The application support directory is not available.",
						details: nil
					))
					break
				}
				let directory = base.appendingPathComponent("Phantrix", isDirectory: true)
				try? fm.createDirectory(
					at: directory,
					withIntermediateDirectories: true,
					attributes: [.posixPermissions: 0o700]
				)
				result(directory.path)
			}
		default:
			result(FlutterMethodNotImplemented)
		}
	}

	// MARK: - Capabilities

	/// What this platform can and cannot do, stated plainly.
	///
	/// Every limitation is reported rather than hidden,
	/// because a UI that offers a control the platform
	/// cannot honour is worse than one that does not.
	private func capabilities() -> [String: Any] {
		var limitations: [String: String] = [
			"kill_switch": "There is no kill switch. If the tunnel drops, "
				+ "traffic returns to the physical interface until the "
				+ "tunnel is re-established.",
			"handshake_verification": "The engine's handshake time is "
				+ "polled from the tunnel process, so a freshly completed "
				+ "handshake may take a few seconds to be observed.",
		]
		return [
			"platform": "apple",
			"killSwitch": false,
			"ipv6Block": true,
			"vpnDns": true,
			"perApp": false,
			"lanBypass": true,
			"alwaysOn": false,
			"tray": false,
			"bootStart": false,
			"engine": "wireguard-apple (WireGuardKit + wireguard-go)",
			"limitations": limitations,
		]
	}

	// MARK: - Permission

	private func requestPermission(_ result: @escaping FlutterResult) {
		manager.load { [weak self] outcome in
			switch outcome {
			case .success:
				// Consent on Apple platforms is granted by
				// installing a configuration, which happens
				// when a tunnel is started. Reporting "true"
				// here would claim consent that has not been
				// given, so the honest answer is whether a
				// configuration is already installed.
				result(self?.manager.isInstalled ?? false)
			case .failure:
				result(false)
			}
		}
	}

	// MARK: - Start

	private func startTunnel(_ arguments: Any?, _ result: @escaping FlutterResult) {
		guard let payload = arguments as? [String: Any] else {
			result(FlutterError(
				code: "config.unreadable",
				message: "The tunnel request was not in a form this platform can read.",
				details: nil,
			))
			return
		}

		let mapping = PhantrixConfigMapper.map(payload)
		let configuration: TunnelConfiguration
		switch mapping {
		case .mapped(let value):
			configuration = value
		case .rejected(let code, let message):
			// The configuration was rejected before it
			// reached the engine, so no tunnel was created
			// and there is nothing to clean up.
			publishFailure(PhantrixTunnelError(code: code, message: message))
			result(FlutterError(code: code, message: message, details: nil))
			return
		}

		manager.load { [weak self] outcome in
			switch outcome {
			case .failure(let error):
				self?.publishFailure(error)
				result(FlutterError(code: error.code, message: error.message, details: nil))
			case .success:
				self?.installAndStart(configuration, result)
			}
		}
	}

	/// Installs [configuration] and activates the tunnel.
	///
	/// The first install is what presents Apple's VPN
	/// authorisation dialog. A decline is reported as a
	/// permission failure rather than as a tunnel failure,
	/// because the two need opposite responses from the
	/// user: one needs them to reconsider, the other needs
	/// them to pick a different server.
	private func installAndStart(_ configuration: TunnelConfiguration, _ result: @escaping FlutterResult) {
		guard let protocolConfiguration = NETunnelProviderProtocol(tunnelConfiguration: configuration) else {
			let error = PhantrixTunnelError(
				code: "config.invalid",
				message: "The tunnel configuration could not be prepared for this platform.",
			)
			publishFailure(error)
			result(FlutterError(code: error.code, message: error.message, details: nil))
			return
		}

		manager.save(protocol: protocolConfiguration) { [weak self] outcome in
			switch outcome {
			case .failure(let error):
				self?.publishFailure(error)
				result(FlutterError(code: error.code, message: error.message, details: nil))
			case .success:
				self?.manager.start { startOutcome in
					switch startOutcome {
					case .failure(let error):
						self?.publishFailure(error)
						result(FlutterError(code: error.code, message: error.message, details: nil))
					case .success:
						// Success here means the operating system
						// accepted the activation request. It is
						// deliberately not reported as connected:
						// only the event stream, once it carries a
						// fresh handshake, may say that.
						self?.publishState(.connecting)
						result(nil)
					}
				}
			}
		}
	}

	// MARK: - Stop

	private func stopTunnel(_ result: @escaping FlutterResult) {
		stopStatsPolling()
		manager.stop { outcome in
			switch outcome {
			case .failure(let error):
				// The tunnel is stopped regardless: the
				// interface is down before the configuration
				// removal can fail, so the failure is
				// reported without leaving the tunnel up.
				self.publishState(.disconnected)
				result(FlutterError(code: error.code, message: error.message, details: nil))
			case .success:
				self.publishState(.disconnected)
				result(nil)
			}
		}
	}

	// MARK: - Settings

	private func openVpnSettings(_ result: @escaping FlutterResult) {
		// iOS and macOS have no public API that opens the
		// VPN settings pane directly. The only supported
		// URL is the app's own settings, which is honest
		// about where the user has to go next.
		#if os(iOS)
		if let url = URL(string: UIApplication.openSettingsURLString) {
			UIApplication.shared.open(url)
		}
		#elseif os(macOS)
		if let url = URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension") {
			NSWorkspace.shared.open(url)
		}
		#endif
		result(nil)
	}

	// MARK: - Events

	private func publishState(_ state: PhantrixTunnelState) {
		guard let eventSink = eventSink else { return }
		eventSink([
			"state": state.wireLabel,
			"traffic": [
				"rx": lastStats.rx,
				"tx": lastStats.tx,
			],
			"lastHandshakeAtMillis": lastStats.handshakeMillis as Any,
			"capabilities": capabilities(),
		])
	}

	private func publishFailure(_ error: PhantrixTunnelError) {
		guard let eventSink = eventSink else { return }
		eventSink([
			"state": "failed",
			"traffic": ["rx": 0, "tx": 0],
			"errorCode": error.code,
			"message": error.message,
			"lastHandshakeAtMillis": lastStats.handshakeMillis as Any,
			"capabilities": capabilities(),
		])
	}

	// MARK: - Engine statistics

	/// Polls the engine for its handshake time and byte
	/// counts.
	///
	/// The operating system's status does not include the
	/// handshake, and the handshake is the fact that
	/// decides whether a tunnel may be called connected.
	/// The engine exposes it through the provider message
	/// channel, which is the same mechanism the upstream
	/// app uses to show its statistics.
	private func startStatsPolling() {
		stopStatsPolling()
		statsTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
			self?.pollStats()
		}
		pollStats()
	}

	private func stopStatsPolling() {
		statsTimer?.invalidate()
		statsTimer = nil
	}

	private func pollStats() {
		let session = manager.connection
		guard let providerSession = session as? NETunnelProviderSession,
		      providerSession.status == .connected else {
			return
		}
		// A single zero byte requests the live runtime
		// configuration, which the extension answers with
		// the engine's own view of the tunnel.
		//
		// The message is thrown rather than returned: the
		// session can reject it when the tunnel is going
		// down. A rejection is not a failure worth
		// reporting, because the next status change will
		// carry the outcome, so it is swallowed here and
		// the absence of a handshake time is left to fail
		// closed in the Dart layer.
		do {
			try providerSession.sendProviderMessage(Data([0])) { [weak self] response in
				guard let self = self, let data = response,
				      let text = String(data: data, encoding: .utf8) else {
					return
				}
				self.applyRuntimeConfiguration(text)
			}
		} catch {
			return
		}
	}

	/// Reads the engine's handshake time and byte counts
	/// out of its runtime configuration.
	///
	/// The format is the engine's own. A value that does
	/// not parse is reported as absent rather than guessed,
	/// because a wrong handshake time would let the Dart
	/// layer claim a connection the engine never made.
	private func applyRuntimeConfiguration(_ text: String) {
		var handshakeMillis: Int64?
		var rx: Int64 = 0
		var tx: Int64 = 0

		if let match = firstCapture(text, pattern: #"LastHandshakeTime\s*=\s*(\d+)"#) {
			// The engine reports whole seconds since the epoch.
			handshakeMillis = (Int64(match) ?? 0) * 1000
		}
		if let match = firstCapture(text, pattern: #"TransferBytes\s*=\s*(\d+),\s*(\d+)"#) {
			// WireGuard reports "rx, tx" in that order.
			let parts = match.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
			if parts.count == 2 {
				rx = Int64(parts[0]) ?? 0
				tx = Int64(parts[1]) ?? 0
			}
		}

		lastStats = (rx: rx, tx: tx, handshakeMillis: handshakeMillis)
		publishState(manager.state)
	}
}

/// Returns the first capture group of [pattern] in [text],
/// or nil when there is no match.
private func firstCapture(_ text: String, pattern: String) -> String? {
	guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
	let range = NSRange(text.startIndex..., in: text)
	guard let match = regex.firstMatch(in: text, range: range),
		  match.numberOfRanges > 1 else {
		return nil
	}
	let captureRange = match.range(at: 1)
	guard let capture = Range(captureRange, in: text) else { return nil }
	return String(text[capture])
}
