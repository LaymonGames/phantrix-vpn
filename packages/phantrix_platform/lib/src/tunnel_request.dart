import 'package:phantrix_core/phantrix_core.dart';

/// A tunnel request handed to the native side.
///
/// Every field is derived from a [VpnConfiguration] that has already passed
/// parsing and security validation.
class TunnelRequest {
  const TunnelRequest({
    required this.configJson,
    required this.killSwitchMode,
    required this.dnsMode,
    required this.customDns,
    required this.ipv6Mode,
    required this.mtuOverride,
    required this.serverId,
    required this.countryLabel,
    this.allowedApps,
    this.disallowedApps,
    this.allowLan,
    this.ovpnConfig,
  });

  final String configJson;
  final String killSwitchMode;
  final String dnsMode;
  final List<String> customDns;
  final String ipv6Mode;
  final int? mtuOverride;
  final String serverId;
  final String countryLabel;
  final List<String>? allowedApps;
  final List<String>? disallowedApps;
  final bool? allowLan;

  /// The complete `.ovpn` profile text for an OpenVPN connection.
  ///
  /// Serialised once, in Dart, by [OvpnSerializer] — full-tunnel routing
  /// already normalised — so the native side never re-implements config
  /// parsing or route policy. Native still re-checks the profile for
  /// execution-capable directives before writing it out; this field is the
  /// single source of what the engine will be told.
  final String? ovpnConfig;

  Map<String, Object?> toMap() => {
    'configJson': configJson,
    'killSwitch': killSwitchMode,
    'dnsMode': dnsMode,
    'customDns': customDns,
    'ipv6': ipv6Mode,
    'mtu': mtuOverride,
    'serverId': serverId,
    'countryLabel': countryLabel,
    if (allowedApps != null) 'allowedApps': allowedApps,
    if (disallowedApps != null) 'disallowedApps': disallowedApps,
    if (allowLan != null) 'allowLan': allowLan,
    if (ovpnConfig != null) 'ovpnConfig': ovpnConfig,
  };
}
