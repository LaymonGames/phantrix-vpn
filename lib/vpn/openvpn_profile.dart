import 'package:phantrix_core/phantrix_core.dart';

/// The `.ovpn` profile the engine is handed, or null when [config] is not
/// OpenVPN.
///
/// Serialised on this side rather than natively so that one implementation
/// decides what the profile says — including the full-tunnel normalisation and
/// the user's IPv6 policy — and the native side only runs a cheap deny-list
/// re-check over it. The text carries the configuration itself and no secrets
/// beyond what the validated configuration already holds; it is never logged.
///
/// IPv6 is blocked unless the user explicitly allows leaking it outside the
/// tunnel. `preferTunnel` still blocks when the configuration cannot carry
/// IPv6 — which for OpenVPN is always, because the profile alone does not say
/// whether the server pushes an IPv6 route.
String? serializeOpenVpnProfile(
  VpnConfiguration config, {
  required Ipv6Mode ipv6Mode,
}) {
  final ovpn = config.openVpn;
  if (ovpn == null) {
    return null;
  }
  final blockIpv6 = switch (ipv6Mode) {
    Ipv6Mode.allow => false,
    Ipv6Mode.block => true,
    Ipv6Mode.preferTunnel => !config.supportsIpv6,
  };
  return OvpnSerializer.serialize(ovpn, blockIpv6: blockIpv6);
}
