// Phantrix packet tunnel extension.
//
// Adapted from the WireGuard for iOS and macOS
// `PacketTunnelProvider`, which is MIT licensed (see
// LICENSE-WireGuardApple). The structure, the error mapping and
// the macOS `exit(0)` workaround are upstream's because they are
// the parts that must match what the WireGuardKit adapter and
// Apple's Network Extension expect. Only the class name, the log
// tag and the error surface are Phantrix's.
//
// ## What this extension does
//
// It is the `com.apple.networkextension.packet-tunnel` provider
// that the operating system launches out of process when the VPN
// is activated. It receives no configuration in the launch
// request: the validated WireGuard configuration was written to
// the shared keychain by the app, and the extension reads it back
// through the `NETunnelProviderProtocol` on `self.protocolConfiguration`.
// It then hands that configuration to `WireGuardAdapter`, which
// owns the tunnel interface and the wireguard-go engine.
//
// ## Why the configuration is not passed directly
//
// `NEPacketTunnelProvider` runs as a separate process with its own
// sandbox. The only sanctioned channel for configuration is the
// `NETunnelProviderProtocol` the app saved via
// `NETunnelProviderManager`, and the only sanctioned place for a
// secret that both processes must read is the shared app-group
// keychain. Anything else — `UserDefaults`, a shared file, an
// intent — would either not be reachable from the extension or
// would be world-readable.

import Foundation
import NetworkExtension
import os

class PhantrixPacketTunnelProvider: NEPacketTunnelProvider {

	private lazy var adapter: WireGuardAdapter = {
		return WireGuardAdapter(with: self) { logLevel, message in
			wg_log(logLevel.osLogLevel, message: message)
		}
	}()

	override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
		let activationAttemptId = options?["activationAttemptId"] as? String
		let errorNotifier = ErrorNotifier(activationAttemptId: activationAttemptId)

		Logger.configureGlobal(tagged: "NET", withFilePath: FileManager.logFileURL?.path)

		wg_log(.info, message: "Starting tunnel from the " + (activationAttemptId == nil ? "OS directly, rather than the app" : "app"))

		guard let tunnelProviderProtocol = self.protocolConfiguration as? NETunnelProviderProtocol,
		      let tunnelConfiguration = tunnelProviderProtocol.asTunnelConfiguration() else {
			// The configuration is missing or unreadable. This is a
			// configuration error, not a network error, and it must
			// be reported as such: the app needs to know to ask the
			// user to re-select a server rather than to retry a
			// connection that was never established.
			errorNotifier.notify(PacketTunnelProviderError.savedProtocolConfigurationIsInvalid)
			completionHandler(PacketTunnelProviderError.savedProtocolConfigurationIsInvalid)
			return
		}

		// Start the tunnel
		adapter.start(tunnelConfiguration: tunnelConfiguration) { adapterError in
			guard let adapterError = adapterError else {
				let interfaceName = self.adapter.interfaceName ?? "unknown"

				wg_log(.info, message: "Tunnel interface is \(interfaceName)")

				completionHandler(nil)
				return
			}

			switch adapterError {
			case .cannotLocateTunnelFileDescriptor:
				wg_log(.error, staticMessage: "Starting tunnel failed: could not determine file descriptor")
				errorNotifier.notify(PacketTunnelProviderError.couldNotDetermineFileDescriptor)
				completionHandler(PacketTunnelProviderError.couldNotDetermineFileDescriptor)

			case .dnsResolution(let dnsErrors):
				let hostnamesWithDnsResolutionFailure = dnsErrors.map { $0.address }
					.joined(separator: ", ")
				wg_log(.error, message: "DNS resolution failed for the following hostnames: \(hostnamesWithDnsResolutionFailure)")
				errorNotifier.notify(PacketTunnelProviderError.dnsResolutionFailure)
				completionHandler(PacketTunnelProviderError.dnsResolutionFailure)

			case .setNetworkSettings(let error):
				wg_log(.error, message: "Starting tunnel failed with setTunnelNetworkSettings returning \(error.localizedDescription)")
				errorNotifier.notify(PacketTunnelProviderError.couldNotSetNetworkSettings)
				completionHandler(PacketTunnelProviderError.couldNotSetNetworkSettings)

			case .startWireGuardBackend(let errorCode):
				wg_log(.error, message: "Starting tunnel failed with wgTurnOn returning \(errorCode)")
				errorNotifier.notify(PacketTunnelProviderError.couldNotStartBackend)
				completionHandler(PacketTunnelProviderError.couldNotStartBackend)

			case .invalidState:
				// Must never happen
				fatalError()
			}
		}
	}

	override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
		wg_log(.info, staticMessage: "Stopping tunnel")

		adapter.stop { error in
			ErrorNotifier.removeLastErrorFile()

			if let error = error {
				wg_log(.error, message: "Failed to stop WireGuard adapter: \(error.localizedDescription)")
			}
			completionHandler()

			#if os(macOS)
			// HACK: This is a filthy hack to work around Apple bug 32073323 (dup'd by us as 47526107).
			// Remove it when they finally fix it upstream and the fix has been rolled out to
			// sufficient quantities of users.
			exit(0)
			#endif
		}
	}

	override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
		guard let completionHandler = completionHandler else { return }

		// A single zero byte is the request for the live runtime
		// configuration. The app uses it to read back what the
		// engine actually applied, which is the only way to report
		// the effective routes and DNS servers rather than the
		// requested ones.
		if messageData.count == 1 && messageData[0] == 0 {
			adapter.getRuntimeConfiguration { settings in
				var data: Data?
				if let settings = settings {
					data = settings.data(using: .utf8)!
				}
				completionHandler(data)
			}
		} else {
			completionHandler(nil)
		}
	}
}

extension WireGuardLogLevel {
	var osLogLevel: OSLogType {
		switch self {
		case .verbose:
			return .debug
		case .error:
			return .error
		}
	}
}
