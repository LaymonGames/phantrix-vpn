/// Which protocol a configuration uses.
///
/// WireGuard is the primary protocol; OpenVPN is kept for servers that only
/// speak it (notably public VPN Gate relays).
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
