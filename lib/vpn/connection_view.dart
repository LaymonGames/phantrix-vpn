import 'package:phantrix_core/phantrix_core.dart';
import 'package:phantrix_platform/phantrix_platform.dart';

/// The snapshot every screen reads instead of asking the controller.
///
/// One immutable value per change means a screen can never assemble a
/// half-updated picture from several getters, and it makes the controller's
/// output something a test can compare directly.
class ConnectionView {
  const ConnectionView({
    required this.state,
    required this.session,
    required this.statusMessage,
    required this.canRetry,
    required this.platform,
    this.errorMessage,
    this.errorCode,
    this.lastFallback,
    this.traffic = PlatformTraffic.empty,
    this.lastHandshakeAt,
    this.selectedLabel,
    this.ipv6Policy = Ipv6Mode.block,
  });

  final VpnState state;
  final ConnectionSession session;
  final String statusMessage;
  final String? errorMessage;
  final String? errorCode;
  final bool canRetry;
  final PlatformCapabilities platform;
  final String? lastFallback;

  /// Real byte counters read from the tunnel engine, not estimates.
  final PlatformTraffic traffic;

  /// When the engine last completed a handshake, or null if never.
  ///
  /// Surfaced so the UI can distinguish "connected" from "the interface is
  /// up but nothing has crossed it yet" without reaching into the engine.
  final DateTime? lastHandshakeAt;

  /// The server the current session, or the last attempt, went to.
  ///
  /// Null when nothing has been chosen. The home screen shows this rather
  /// than asking the resolver, so the label on screen is the same one the
  /// connection was actually made with — a label assembled somewhere else
  /// could disagree with where the traffic is really going.
  final String? selectedLabel;

  /// The IPv6 policy in force for the next connection.
  ///
  /// Carried on the view because the home screen reports it as part of the
  /// session panel, and reading the settings controller from a screen would
  /// mean a second source of truth for what is about to be applied.
  final Ipv6Mode ipv6Policy;

  static const ConnectionView initial = ConnectionView(
    state: VpnState.disconnected,
    session: ConnectionSession.none,
    statusMessage: 'Not connected.',
    canRetry: false,
    platform: PlatformCapabilities.web,
    ipv6Policy: Ipv6Mode.block,
  );

  bool get isConnected => state.isConnected;
  bool get isBusy => state.isTransitioning;
}
