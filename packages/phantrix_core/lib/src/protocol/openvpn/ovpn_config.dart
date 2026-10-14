
/// A single OpenVPN remote (`remote host port proto`).
class OvpnRemote {
	const OvpnRemote({required this.host, required this.port, this.proto});

	final String host;
	final int port;
	final String? proto;

	@override
	String toString() => '$host:$port${proto == null ? '' : '/$proto'}';
}

/// An inline certificate/key block from an `.ovpn` file.
class OvpnInlineBlock {
	const OvpnInlineBlock(this.tag, this.body);

	final String tag;
	final String body;

	bool get isPrivateKey => tag == 'key' || tag == 'tls-crypt-v2';
}

/// A parsed OpenVPN configuration.
///
/// Every security-relevant decision lives in OvpnValidator; this class only
/// holds structure.
class OvpnConfig {
	const OvpnConfig({
		this.remotes = const [],
		this.proto,
		this.dev,
		this.cipher,
		this.dataCiphers = const [],
		this.auth,
		this.tlsVersionMin,
		this.tlsCertProfile,
		required this.authUserPass,
		this.authUserPassFile,
		this.caFile,
		this.certFile,
		this.keyFile,
		this.inlineBlocks = const {},
		this.caPath,
		this.pull,
		this.redirectGateway,
		this.dhcpOptionDns = const [],
		this.routeNopull = false,
		this.verbosity,
		this.rawDirectives = const {},
		this.comments = const [],
		this.unknownDirectives = const {},
	});

	final List<OvpnRemote> remotes;
	final String? proto;
	final String? dev;
	final String? cipher;
	final List<String> dataCiphers;
	final String? auth;
	final String? tlsVersionMin;
	final String? tlsCertProfile;
	final bool authUserPass;
	final String? authUserPassFile;
	final String? caFile;
	final String? certFile;
	final String? keyFile;

	/// Inline `<tag>` blocks. `ca`, `cert`, `key`, `tls-auth`, `tls-crypt`,
	/// `tls-crypt-v2`, `extra-certs`.
	final Map<String, OvpnInlineBlock> inlineBlocks;

	final String? caPath;
	final bool? pull;
	final bool? redirectGateway;
	final List<String> dhcpOptionDns;
	final bool routeNopull;
	final int? verbosity;

	/// Preserved, never acted upon: PreUp-style and plugin directives.
	final Map<String, String> rawDirectives;
	final List<String> comments;
	final Map<String, String> unknownDirectives;

	bool get hasCa => inlineBlocks.containsKey('ca');
}

/// One line of a parsed OpenVPN configuration file, kept for diagnostics.
class OvpnDirective {
	const OvpnDirective(this.key, this.value, {this.line});

	final String key;
	final String value;
	final int? line;

	@override
	String toString() => '$key $value';
}
