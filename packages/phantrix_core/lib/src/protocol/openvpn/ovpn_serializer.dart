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
  /// [blockIpv6] appends OpenVPN's `block-ipv6`. This only rejects IPv6
  /// packets routed into the TUN device; it is not a host firewall and does
  /// not prove that the physical interface's IPv6 route is blocked.
  static String serialize(OvpnConfig config, {bool blockIpv6 = false}) {
    final buffer = StringBuffer(headerComment);
    buffer.writeln();
    buffer.writeln('client');
    buffer.writeln('dev tun');
    final proto = config.proto ?? 'udp';
    buffer.writeln('proto $proto');
    for (final remote in config.remotes) {
      final transport = remote.proto == null ? '' : ' ${remote.proto}';
      buffer.writeln('remote ${remote.host} ${remote.port}$transport');
    }
    // A CA alone does not distinguish a VPN server from another client
    // certificate issued by that CA.
    buffer.writeln('remote-cert-tls server');
    if (config.verifyX509Name != null) {
      buffer.writeln('verify-x509-name ${config.verifyX509Name}');
    }
    if (config.tlsVersionMin != null) {
      buffer.writeln('tls-version-min ${config.tlsVersionMin}');
    }
    if (config.tlsCertProfile != null) {
      buffer.writeln('tls-cert-profile ${config.tlsCertProfile}');
    }
    if (config.keyDirection != null) {
      buffer.writeln('key-direction ${config.keyDirection}');
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
    if (config.dataCiphers.isNotEmpty) {
      buffer.writeln('data-ciphers ${config.dataCiphers.join(':')}');
    } else if (cipher != null && cipher.isNotEmpty) {
      buffer.writeln('data-ciphers $cipher');
    }
    final fallback = config.dataCiphersFallback ?? cipher;
    if (fallback != null && fallback.isNotEmpty) {
      buffer.writeln('data-ciphers-fallback $fallback');
    }
    for (final tag in const [
      'ca',
      'cert',
      'key',
      'tls-auth',
      'tls-crypt',
      'tls-crypt-v2',
      'extra-certs',
    ]) {
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
    final remotes = config.remotes.map((r) => '${r.host}:${r.port}').toList()
      ..sort();
    final blocks = config.inlineBlocks.keys.toList()..sort();
    final ca = config.inlineBlocks['ca']?.body.trim();
    return '${remotes.join(',')}|${blocks.join(',')}|${_shortHash(ca ?? '')}';
  }

  static String _shortHash(String value) => fingerprintHex(value);
}
