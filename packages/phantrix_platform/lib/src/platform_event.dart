import 'platform_capabilities.dart';
import 'platform_traffic.dart';
import 'platform_tunnel_state.dart';

/// Live platform facts, pushed from the native side.
class PlatformEvent {
  const PlatformEvent({
    required this.state,
    required this.traffic,
    this.message,
    this.errorCode,
    this.capabilities,
    this.networkChanged = false,
    this.lastHandshakeAtMillis,
  });

  final PlatformTunnelState state;
  final PlatformTraffic traffic;

  /// Unix milliseconds of the last handshake the engine observed.
  ///
  /// Null when no handshake has happened yet, which is materially different
  /// from a handshake at the epoch: the first means the peer has never answered,
  /// the second means it did and the reading is stale.
  final int? lastHandshakeAtMillis;

  /// A short, non-secret human message.
  final String? message;

  /// A stable machine code, for example `wg.handshake_timeout`.
  final String? errorCode;

  /// Reported by the platform on start-up and after a capability change.
  final PlatformCapabilities? capabilities;

  /// True when the OS reported that the underlying network changed.
  final bool networkChanged;
}
