// Phantrix's app-side VPN manager.
//
// Wraps `NETunnelProviderManager`, which is the only
// supported way for an app to install and activate a
// packet-tunnel configuration. It owns the
// `NETunnelProviderProtocol` that points at the Phantrix
// extension, saves it (which is what triggers Apple's
// VPN consent dialog the first time), starts and stops
// the tunnel, and publishes status changes.
//
// ## Why a manager rather than a direct start
//
// `NEPacketTunnelProvider` is launched by the operating
// system, never by the app directly. The app installs a
// `NETunnelProviderProtocol` through a
// `NETunnelProviderManager`, and the OS then starts the
// extension. Any code that tried to start the extension
// itself would be using a private API.
//
// ## Why the manager is loaded, not created
//
// `NETunnelProviderManager.loadAllFromPreferences` returns
// every saved VPN configuration. A manager for Phantrix is
// reused when one already exists, because saving a fresh
// manager each time would install a second, third, fourth
// VPN configuration for the same extension, and the OS
// would ask the user to authorise each one.

import Foundation
import NetworkExtension

/// The operating-system status of the tunnel, mapped onto
/// Phantrix's own states so the Dart layer receives one
/// vocabulary across every platform.
enum PhantrixTunnelState: String {
	case disconnected = "disconnected"
	case connecting = "connecting"
	case connected = "connected"
	case disconnecting = "disconnecting"
	case failed = "failed"

	init(osStatus: NEVPNStatus) {
		switch osStatus {
		case .invalid:
			// The manager exists but has no configuration
			// loaded. That is a form of disconnected, not a
			// failure: reporting it as failed would make a
			// fresh install look broken.
			self = .disconnected
		case .disconnected:
			self = .disconnected
		case .connecting, .reasserting:
			// Reasserting means the OS is re-establishing the
			// tunnel, which is a transitional connecting state.
			self = .connecting
		case .connected:
			self = .connected
		case .disconnecting:
			self = .disconnecting
		@unknown default:
			// A status added after this was written must not
			// crash the app, and must not be reported as
			// connected. Disconnected is the only safe choice.
			self = .disconnected
		}
	}

	/// The label the Dart layer's event decoder expects.
	///
	/// The Dart platform state has no "disconnected" case:
	/// a tunnel the OS reports as down is "idle", because
	/// idle is the state a tunnel is in before it has ever
	/// been asked to start. Mapping to anything else would
	/// make a fresh install look like a failure.
	var wireLabel: String {
		switch self {
		case .disconnected:
			return "idle"
		case .connecting:
			return "connecting"
		case .connected:
			// The interface is up. This is "established",
			// never "connected": the Dart layer promotes to
			// connected only after it has verified a fresh
			// handshake and a changed public address.
			return "established"
		case .disconnecting:
			return "disconnecting"
		case .failed:
			return "failed"
		}
	}
}

/// A failure observed while managing the tunnel, with the
/// code the Dart layer reports. The code is stable and is
/// what the UI keys on, so it must never change meaning.
struct PhantrixTunnelError: Error, Equatable {
	let code: String
	let message: String

	/// The error the extension wrote to the shared container
	/// when it could not start, or nil when there is none.
	///
	/// The extension runs out of process and cannot call
	/// back into this manager, so it reports failures by
	/// writing `activationAttemptId\nerror` to the app-group
	/// container. Reading that file is how a start that
	/// failed inside the extension becomes a failure the
	/// user can see.
	static func fromLastErrorFile() -> PhantrixTunnelError? {
		guard let url = FileManager.networkExtensionLastErrorFileURL,
		      let contents = try? String(contentsOf: url, encoding: .utf8) else {
			return nil
		}
		// The file is "<activationAttemptId>\n<error>". The
		// attempt id is correlation data, not a message, so
		// only the second line is surfaced.
		let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
		guard lines.count >= 2, let error = PacketTunnelProviderError(rawValue: String(lines[1])) else {
			return nil
		}
		switch error {
		case .savedProtocolConfigurationIsInvalid:
			return PhantrixTunnelError(
				code: "config.invalid",
				message: "The saved tunnel configuration is invalid. Select the server again.",
			)
		case .dnsResolutionFailure:
			return PhantrixTunnelError(
				code: "tunnel.dns_resolution",
				message: "The server's address could not be resolved.",
			)
		case .couldNotStartBackend:
			return PhantrixTunnelError(
				code: "tunnel.failed",
				message: "The WireGuard engine could not be started.",
			)
		case .couldNotDetermineFileDescriptor:
			return PhantrixTunnelError(
				code: "tunnel.failed",
				message: "The tunnel interface could not be created.",
			)
		case .couldNotSetNetworkSettings:
			return PhantrixTunnelError(
				code: "tunnel.failed",
				message: "The operating system refused the tunnel's network settings.",
			)
		}
	}
}

/// Owns the tunnel's lifecycle and publishes every change.
final class PhantrixVPNManager: NSObject {
	/// The extension this manager controls. The bundle
	/// identifier suffix is fixed because it is baked into
	/// the saved protocol, and changing it would orphan the
	/// configuration the user already authorised.
	private let providerBundleIdSuffix = ".network-extension"

	/// The saved manager, once loaded. Every operation
	/// goes through this rather than through a fresh
	/// instance, so the same configuration is updated
	/// instead of duplicated.
	private var manager: NETunnelProviderManager?

	private var statusToken: NotificationToken?
	private var onState: ((PhantrixTunnelState) -> Void)?
	private var onError: ((PhantrixTunnelError) -> Void)?

	/// Whether a configuration is installed and authorised.
	///
	/// This is the honest answer to "can the tunnel start":
	/// a tunnel whose preferences were never saved cannot
	/// start, and claiming otherwise would be the same lie
	/// as reporting connected without a handshake.
	var isInstalled: Bool {
		return manager?.protocolConfiguration != nil
	}

	/// Loads the saved preferences, reusing the existing
	/// Phantrix configuration when there is one.
	///
	/// `loadAllFromPreferences` is asynchronous and may
	/// prompt. Its failure is reported rather than
	/// swallowed, because a silent failure here would leave
	/// the app believing a tunnel exists when it does not.
	func load(completion: @escaping (Result<Void, PhantrixTunnelError>) -> Void) {
		NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
			if let error = error {
				completion(.failure(PhantrixTunnelError(
					code: "permission.denied",
					message: "The VPN configuration could not be loaded: \(error.localizedDescription).",
				)))
				return
			}
			// Reuse the configuration that belongs to this
			// app's extension, identified by the provider
			// bundle identifier the protocol carries.
			let existing = (managers ?? []).first { manager in
				guard let provider = manager.protocolConfiguration as? NETunnelProviderProtocol else {
					return false
				}
				return provider.providerBundleIdentifier?.hasSuffix(".network-extension") == true
			}
			self?.manager = existing ?? NETunnelProviderManager()
			if let existing = existing {
				self?.observe(existing)
			}
			completion(.success(()))
		}
	}

	/// Installs [protocol] as the tunnel's configuration.
	///
	/// The first save is what presents Apple's VPN
	/// authorisation dialog. This method never suppresses
	/// that prompt and never caches a credential: the
	/// operating system owns consent, and the app only
	/// learns the outcome through this callback.
	func save(protocol: NETunnelProviderProtocol, completion: @escaping (Result<Void, PhantrixTunnelError>) -> Void) {
		guard let manager = manager else {
			completion(.failure(PhantrixTunnelError(
				code: "config.invalid",
				message: "The VPN configuration has not been loaded.",
			)))
			return
		}
		manager.protocolConfiguration = `protocol`
		manager.isEnabled = true
		manager.saveToPreferences { error in
			if let error = error {
				completion(.failure(PhantrixTunnelError(
					code: "permission.denied",
					message: "The VPN configuration could not be saved: \(error.localizedDescription).",
				)))
				return
			}
			completion(.success(()))
		}
	}

	/// Starts the tunnel.
	///
	/// Activation can fail either here, before the extension
	/// is even launched, or inside the extension. Both are
	/// handled: the synchronous failure is reported
	/// directly, and the extension-side failure is read from
	/// the shared container after a short delay, which is
	/// the window the OS needs to write it.
	func start(completion: @escaping (Result<Void, PhantrixTunnelError>) -> Void) {
		guard let manager = manager,
		      let protocolConfiguration = manager.protocolConfiguration as? NETunnelProviderProtocol else {
			completion(.failure(PhantrixTunnelError(
				code: "config.invalid",
				message: "No tunnel configuration is installed. Select a server first.",
			)))
			return
		}

		let attemptId = UUID().uuidString
		do {
			try manager.connection.startVPNTunnel(options: ["activationAttemptId": attemptId])
		} catch {
			completion(.failure(PhantrixTunnelError(
				code: "tunnel.failed",
				message: "The tunnel could not be activated: \(error.localizedDescription).",
			)))
			return
		}

		// The extension may fail after this returns, and the
		// only record of that is in the shared container.
		// Poll briefly rather than reporting success for a
		// tunnel that is about to die.
		DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
			if let error = PhantrixTunnelError.fromLastErrorFile() {
				self.onError?(error)
			} else {
				completion(.success(()))
			}
		}
	}

	/// Stops the tunnel and removes the configuration,
	/// which deletes the private key from the keychain.
	///
	/// The key is deleted here rather than left in the
	/// keychain, because a private key that outlives the
	/// tunnel it belongs to is a credential leak: it would
	/// remain readable by the app after the user believed
	/// the connection was gone.
	func stop(completion: @escaping (Result<Void, PhantrixTunnelError>) -> Void) {
		guard let manager = manager else {
			completion(.success(()))
			return
		}
		manager.connection.stopVPNTunnel()
		if let protocolConfiguration = manager.protocolConfiguration as? NETunnelProviderProtocol {
			protocolConfiguration.destroyConfigurationReference()
		}
		manager.removeFromPreferences { error in
			if let error = error {
				completion(.failure(PhantrixTunnelError(
					code: "tunnel.failed",
					message: "The tunnel configuration could not be removed: \(error.localizedDescription).",
				)))
				return
			}
			completion(.success(()))
		}
	}

	/// The operating system's current status.
	var state: PhantrixTunnelState {
		return PhantrixTunnelState(osStatus: manager?.connection.status ?? .invalid)
	}

	/// The connection whose statistics are polled.
	var connection: NEVPNConnection {
		return manager?.connection ?? NEVPNConnection()
	}

	/// Subscribes to state and error events.
	func observe(onState: @escaping (PhantrixTunnelState) -> Void, onError: @escaping (PhantrixTunnelError) -> Void) {
		self.onState = onState
		self.onError = onError
	}

	private func observe(_ manager: NETunnelProviderManager) {
		// Status changes arrive as a notification on the
		// manager's connection, not as a delegate callback.
		statusToken?.notificationCenter.removeObserver(statusToken!.token)
		statusToken = NotificationCenter.default.observe(
			name: .NEVPNStatusDidChange,
			object: manager.connection,
			queue: .main,
		) { [weak self] _ in
			self?.publishState()
		}
	}

	private func publishState() {
		onState?(state)
	}
}
