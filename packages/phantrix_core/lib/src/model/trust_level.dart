/// How much the user should trust a server.
///
/// This is *not* a statement about the encryption on the wire - WireGuard and
/// OpenVPN both encrypt. It is a statement about the exit point: the operator
/// of the server can observe your traffic once it leaves the tunnel.
enum TrustLevel {
	/// Run by this project and independently audited.
	projectVerified('Project operated', 'Operated by Phantrix and independently checked.'),

	/// Run by a known community operator that has been reviewed.
	community('Community', 'Operated by a reviewed community participant.'),

	/// Published by a public, volunteer network. No trust relationship exists.
	publicRelay('Public relay', 'Operated by an unknown volunteer. They can see your traffic.'),

	/// A configuration the user supplied; nothing about it is verified.
	imported('Imported', 'You supplied this configuration. Nothing about it is verified.'),

	/// Unknown source.
	unknown('Unknown', 'No trust information available for this server.');

	const TrustLevel(this.label, this.explanation);

	final String label;
	final String explanation;

	/// Whether we present this server with a trust warning.
	bool get requiresWarning =>
			this == TrustLevel.publicRelay || this == TrustLevel.imported || this == TrustLevel.unknown;
}
