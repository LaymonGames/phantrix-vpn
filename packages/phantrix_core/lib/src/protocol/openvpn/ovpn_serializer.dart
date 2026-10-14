import '../../logging/fingerprint.dart';

import 'ovpn_config.dart';

/// Deterministic OpenVPN serialiser. Used to hand a configuration to the
/// platform tunnel and to export an imported file.
///
/// Components that can execute code are never written back out. If the input
/// contained them, the caller has already rejected the file.
class OvpnSerializer {
	const OvpnSerializer._();

	static const String headerComment =
		'# Rebuilt by Phantrix. Routed directives are normalised for a full tunnel.';

	/// Serialises [config] to `.ovpn` profile text.
	///
	/// [blockIpv6] appends OpenVPN's `block-ipv6`, which is how the user's
	/// IPv6 policy is honoured on platforms where the config cannot carry
	/// IPv6 itself: blocked rather than silently leaking over the physical
	/// interface. It is only passed when the policy allows leakage — the
	/// default is to block.
	static String serialize(OvpnConfig config, {bool blockIpv6 = false}) {
		final buffer = StringBuffer(headerComment);
		buffer.writeln();
		buffer.writeln('client');
		buffer.writeln('dev ${config.dev ?? 'tun'}');
		final proto = config.proto ?? 'udp';
		buffer.writeln('proto $proto');
		for (final remote in config.remotes) {
			buffer.writeln('remote ${remote.host} ${remote.port}');
		}
		buffer.writeln('resolv-retry infinite');
		buffer.writeln('nobind');
		buffer.writeln('persist-key');
		buffer.writeln('persist-tun');
		buffer.writeln('pull-filter ignore "redirect-gateway"');
		buffer.writeln('redirect-gateway def1 bypass-dhcp');
		if (blockIpv6) {
			buffer.writeln('block-ipv6');
		}
		buffer.writeln('verb ${config.verbosity ?? 3}');
		final auth = config.auth;
		if (auth != null && auth.isNotEmpty) {
			buffer.writeln('auth $auth');
		}
		final cipher = config.cipher;
		if (cipher != null && cipher.isNotEmpty) {
			buffer.writeln('data-ciphers $cipher');
			buffer.writeln('data-ciphers-fallback $cipher');
		} else if (config.dataCiphers.isNotEmpty) {
			buffer.writeln('data-ciphers ${config.dataCiphers.join(':')}');
		}
		for (final tag in const ['ca', 'cert', 'key', 'tls-auth', 'tls-crypt']) {
			final block = config.inlineBlocks[tag];
			if (block == null) {
				continue;
			}
			buffer.writeln();
			buffer.writeln('<$tag>');
			buffer.write(block.body.endsWith('\n') ? block.body : '${block.body}\n');
			buffer.writeln('</$tag>');
		}
		if (config.authUserPass) {
			buffer.writeln();
			buffer.writeln('auth-user-pass');
		}
		return buffer.toString();
	}

	/// Non-private fingerprint used to de-duplicate servers that pop up in
	/// several places with different scores.
	static String fingerprint(OvpnConfig config) {
		final remotes = config.remotes.map((r) => '${r.host}:${r.port}').toList()..sort();
		final blocks = config.inlineBlocks.keys.toList()..sort();
		final ca = config.inlineBlocks['ca']?.body.trim();
		return '${remotes.join(',')}|${blocks.join(',')}|${_shortHash(ca ?? '')}';
	}

	static String _shortHash(String value) => fingerprintHex(value);
}
