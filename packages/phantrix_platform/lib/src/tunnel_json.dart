import 'dart:convert';

import 'package:phantrix_core/phantrix_core.dart';

/// JSON encoding shared with the native side.
///
/// The payload never leaves the device. The native side is responsible for
/// keeping it out of its own logs.
class TunnelJson {
  const TunnelJson._();

  /// Serialises a validated configuration for the platform tunnel.
  static String encode(VpnConfiguration config) {
    final openVpn = config.openVpn;
    final json = <String, Object?>{
      'kind': config.kind.name,
      if (openVpn != null)
        'openvpn': {
          'proto': openVpn.proto,
          'dev': openVpn.dev,
          'cipher': openVpn.cipher,
          'auth': openVpn.auth,
          'remotes': openVpn.remotes
              .map((r) => {'host': r.host, 'port': r.port, 'proto': r.proto})
              .toList(),
          'ca': openVpn.inlineBlocks['ca']?.body,
          'cert': openVpn.inlineBlocks['cert']?.body,
          'key': openVpn.inlineBlocks['key']?.body,
          'tlsAuth': openVpn.inlineBlocks['tls-auth']?.body,
          'authUserPass': openVpn.authUserPass,
        },
    };
    return jsonEncode(json);
  }
}
