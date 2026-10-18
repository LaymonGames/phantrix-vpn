import '../core/app_error.dart';
import '../core/result.dart';
import '../model/vpn_server.dart';
import '../protocol/protocol_kind.dart';
import '../protocol/vpn_configuration.dart';

/// What a specific platform can actually do.
///
/// The UI must never offer a switch the platform will silently ignore. Where
/// a capability is missing the settings screen reads "not supported on this
/// platform" instead.
class TunnelEngineCapabilities {
  const TunnelEngineCapabilities({
    required this.supportsKillSwitch,
    required this.killSwitchStrictness,
    required this.supportsIpv6Blocking,
    required this.supportsVpnProvidedDns,
    required this.supportsPerAppSplitTunnelling,
    required this.supportsLanBypass,
    required this.supportsAlwaysOn,
    required this.supportsAutoConnectOnUntrustedWifi,
    required this.supportsTray,
    required this.platformName,
    this.limitations = const {},
  });

  /// True when the platform can guarantee, rather than approximate, a kill
  /// switch.
  final bool supportsKillSwitch;

  /// `off`, `automatic` or `strict`.
  final String killSwitchStrictness;

  final bool supportsIpv6Blocking;
  final bool supportsVpnProvidedDns;
  final bool supportsPerAppSplitTunnelling;
  final bool supportsLanBypass;

  /// True on Android when "always-on VPN" can be requested.
  final bool supportsAlwaysOn;

  /// True on desktop, where the OS reports the current network name.
  final bool supportsAutoConnectOnUntrustedWifi;

  /// True on desktop, where a tray or menu bar is available.
  final bool supportsTray;

  final String platformName;

  /// Human-readable explanations of what this platform cannot do.
  final Map<String, String> limitations;

  static const TunnelEngineCapabilities web = TunnelEngineCapabilities(
    supportsKillSwitch: false,
    killSwitchStrictness: 'off',
    supportsIpv6Blocking: false,
    supportsVpnProvidedDns: false,
    supportsPerAppSplitTunnelling: false,
    supportsLanBypass: false,
    supportsAlwaysOn: false,
    supportsAutoConnectOnUntrustedWifi: false,
    supportsTray: false,
    platformName: 'web',
    limitations: {
      'kill_switch':
          'A browser cannot protect traffic outside itself. Only a system-wide '
          'client on Windows, macOS, Linux, Android or iOS can do that.',
    },
  );
}

/// The engine abstraction each platform implements.
///
/// Rules the implementations must honour:
///  * [connect] may only emit `tunnelVerified` once the tunnel is genuinely
///    up and the address is known;
///  * [disconnect] must always clean up, even after a crash mid-connect;
///  * any error must be an [AppError], never a silent success.
abstract class VpnEngine {
  /// What this platform supports.
  Future<TunnelEngineCapabilities> capabilities();

  /// Brings up the tunnel described by [config] for [server].
  ///
  /// Implementations emit events through [events], and must never claim
  /// success before verification.
  Future<Result<void>> connect(
    VpnConfiguration config, {
    required VpnServer server,
    required String countryLabel,
  });

  /// Tears the tunnel down and restores the previous network state.
  Future<Result<void>> disconnect();

  /// Applies the kill switch. Returns an error when the platform cannot.
  Future<Result<void>> setKillSwitch(String mode);

  /// Requests the platform VPN permission (Android, iOS, macOS).
  Future<Result<void>> requestPermission();

  Stream<VpnEngineEvent> get events;

  /// The last known protocol the engine is using.
  ProtocolKind? get activeProtocol;
}

/// Events the engine reports to the state machine.
sealed class VpnEngineEvent {
  const VpnEngineEvent();
}

final class EngineStateChanged extends VpnEngineEvent {
  const EngineStateChanged(this.detail);
  final String detail;
}

final class EngineTunnelUp extends VpnEngineEvent {
  const EngineTunnelUp(
    this.assignedIpv4,
    this.assignedIpv6,
    this.protocolLabel,
  );

  final String? assignedIpv4;
  final String? assignedIpv6;
  final String? protocolLabel;
}

final class EngineVerified extends VpnEngineEvent {
  const EngineVerified(
    this.assignedIpv4,
    this.assignedIpv6,
    this.protocolLabel,
  );
  final String? assignedIpv4;
  final String? assignedIpv6;
  final String? protocolLabel;
}

final class EngineHandshake extends VpnEngineEvent {
  const EngineHandshake(this.time);
  final DateTime time;
}

final class EngineTraffic extends VpnEngineEvent {
  const EngineTraffic(this.rxBytes, this.txBytes, this.rxRate, this.txRate);
  final int rxBytes;
  final int txBytes;
  final int? rxRate;
  final int? txRate;
}

final class EngineFailed extends VpnEngineEvent {
  const EngineFailed(this.error);
  final AppError error;
}
