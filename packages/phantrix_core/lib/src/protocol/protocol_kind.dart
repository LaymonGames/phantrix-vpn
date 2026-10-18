/// Which protocol a configuration uses.
///
/// Two peers, and neither is a fallback for the other in general: WireGuard
/// is what an imported configuration speaks, and OpenVPN is what the built-in
/// public feed speaks. Which one the app reaches for first is the user's
/// choice — `AppSettings.preferredProtocol`, OpenVPN by default — rather than
/// a property of this enum.
enum ProtocolKind {
  wireGuard('WireGuard'),
  openVpn('OpenVPN');

  const ProtocolKind(this.label);

  final String label;

  String get shortLabel => switch (this) {
    ProtocolKind.wireGuard => 'WG',
    ProtocolKind.openVpn => 'OVPN',
  };
}
