/// The state a platform reports for its tunnel.
///
/// This mirrors, but is not the same as, `VpnState`. The platform describes
/// what the OS is doing; the state machine decides what that means. In
/// particular `established` is never the same as connected.
enum PlatformTunnelState {
  idle('idle'),
  preparing('preparing'),
  connecting('connecting'),
  established('established'),

  /// The engine holds the interface and has completed the protocol's
  /// handshake with the peer recently — OpenVPN's "Initialization Sequence
  /// Completed" on Windows, or a WireGuard handshake on a platform whose
  /// backend runs one — with the time of that event in the event's
  /// `lastHandshakeAtMillis`.
  ///
  /// This is a stronger claim than [established] and a weaker one than a
  /// verified leak check. The distinction exists because "the tunnel
  /// interface is up" and "the peer answered" are different facts, and
  /// only the second one proves anything is being carried.
  ///
  /// For OpenVPN the native side must refresh `lastHandshakeAtMillis` on
  /// every reconnect, so the freshness check the Dart side applies measures
  /// the current session rather than one from a previous network.
  handshaked('handshaked'),
  reconnecting('reconnecting'),
  disconnecting('disconnecting'),
  failed('failed'),
  revoked('revoked');

  const PlatformTunnelState(this.label);

  final String label;

  static PlatformTunnelState fromWire(String value) => switch (value) {
    'idle' => PlatformTunnelState.idle,
    'preparing' => PlatformTunnelState.preparing,
    'connecting' => PlatformTunnelState.connecting,
    'established' => PlatformTunnelState.established,
    'handshaked' => PlatformTunnelState.handshaked,
    'reconnecting' => PlatformTunnelState.reconnecting,
    'disconnecting' => PlatformTunnelState.disconnecting,
    'failed' => PlatformTunnelState.failed,
    'revoked' => PlatformTunnelState.revoked,
    _ => PlatformTunnelState.idle,
  };
}
