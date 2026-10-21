import 'package:phantrix_core/src/protocol/openvpn/ovpn_parser.dart';
import 'package:phantrix_core/src/protocol/openvpn/ovpn_serializer.dart';
import 'package:phantrix_core/src/protocol/openvpn/ovpn_validator.dart';
import 'package:test/test.dart';

const String kCa = '''
-----BEGIN CERTIFICATE-----
MIIFazCCA1OgAwIBAgIRAIIQz7DSQONZRGPgu2OCiwAwDQYJKoZIhvcNAQELBQAw
TzELMAkGA1UEBhMCVVMxKTAnBgNVBAoTIEludGVybmV0IFNlY3VyaXR5IFJlc2Vh
-----END CERTIFICATE-----
''';

String baseConfig() =>
    '''
client
dev tun
proto udp
remote vpn.example.net 1194
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
cipher AES-256-GCM
auth SHA256

<ca>
$kCa
</ca>
''';

String withDirective(String directive) => baseConfig() + directive;

void main() {
  group('OvpnParser', () {
    test('default and global ports do not depend on directive order', () {
      final tcp = OvpnParser.parse('proto tcp\nremote vpn.example.net').valueOr;
      expect(tcp.remotes.single.port, 1194);
      final global = OvpnParser.parse(
        'remote vpn.example.net\nport 8443',
      ).valueOr;
      expect(global.remotes.single.port, 8443);
    });

    test('reads remotes, ciphers and inline blocks', () {
      final result = OvpnParser.parse(baseConfig());
      expect(result.isOk, isTrue);
      final config = result.valueOr;
      expect(config.remotes, hasLength(1));
      expect(config.remotes.first.host, 'vpn.example.net');
      expect(config.remotes.first.port, 1194);
      expect(config.proto, 'udp');
      expect(config.cipher, 'AES-256-GCM');
      expect(config.inlineBlocks.containsKey('ca'), isTrue);
    });

    test('reports an unterminated inline block', () {
      final result = OvpnParser.parse('''
remote 1.2.3.4 1194
<ca>
$kCa
''');
      expect(result.isOk, isFalse);
      expect(result.errorOrNull?.code, 'ovpn.unterminated_block');
    });
  });

  group('OvpnValidator', () {
    test('rejects a non-numeric explicit remote port', () {
      final parsed = OvpnParser.parse(
        baseConfig().replaceFirst('1194', 'not-a-port'),
      ).valueOr;
      expect(
        OvpnValidator.validate(parsed).errorOrNull?.code,
        'ovpn.remote_port',
      );
    });

    test('does not silently remove a null data cipher', () {
      for (final option in ['data-ciphers', 'data-ciphers-fallback']) {
        final parsed = OvpnParser.parse(
          withDirective('\n$option none'),
        ).valueOr;
        expect(
          OvpnValidator.validate(parsed).errorOrNull?.code,
          'ovpn.broken_cipher',
        );
      }
    });

    test('rejects server-mode transports and malformed IPv6', () {
      final transport = OvpnParser.parse(
        baseConfig().replaceFirst('proto udp', 'proto tcp-server'),
      ).valueOr;
      expect(OvpnValidator.validate(transport).isOk, isFalse);
      final host = OvpnParser.parse(
        baseConfig().replaceFirst('vpn.example.net', ':::'),
      ).valueOr;
      expect(
        OvpnValidator.validate(host).errorOrNull?.code,
        'ovpn.remote_host',
      );
    });

    test('accepts a sane configuration', () {
      final parsed = OvpnParser.parse(baseConfig()).valueOr;
      final verdict = OvpnValidator.validate(parsed);
      expect(verdict.isOk, isTrue);
      expect(verdict.valueOr.isSafe, isTrue);
    });

    test('rejects a configuration that can run commands', () {
      final text = withDirective('\nup /bin/sh');
      final parsed = OvpnParser.parse(text).valueOr;
      final verdict = OvpnValidator.validate(parsed);
      expect(verdict.isOk, isFalse);
      expect(verdict.errorOrNull?.code, 'ovpn.forbidden_directive');
    });

    test('rejects plugin loading', () {
      final text = withDirective('\nplugin /tmp/evil.so');
      final parsed = OvpnParser.parse(text).valueOr;
      final verdict = OvpnValidator.validate(parsed);
      expect(verdict.isOk, isFalse);
      expect(verdict.errorOrNull?.code, 'ovpn.forbidden_directive');
    });

    test('rejects script-security 2', () {
      final text = withDirective('\nscript-security 2');
      final parsed = OvpnParser.parse(text).valueOr;
      final verdict = OvpnValidator.validate(parsed);
      expect(verdict.isOk, isFalse);
      expect(verdict.errorOrNull?.code, 'ovpn.script_security');
    });

    test('rejects an external trust file', () {
      final text = '''
client
dev tun
remote 1.2.3.4 1194
ca /etc/openvpn/server.crt
cipher AES-256-GCM
''';
      final parsed = OvpnParser.parse(text).valueOr;
      final verdict = OvpnValidator.validate(parsed);
      expect(verdict.isOk, isFalse);
      expect(verdict.errorOrNull?.code, 'ovpn.external_file_forbidden');
    });

    test('rejects authentication being switched off', () {
      final text =
          '''
client
dev tun
remote 1.2.3.4 1194
auth none
cipher AES-256-GCM
<ca>
$kCa
</ca>
''';
      final parsed = OvpnParser.parse(text).valueOr;
      final verdict = OvpnValidator.validate(parsed);
      expect(verdict.isOk, isFalse);
      expect(verdict.errorOrNull?.code, 'ovpn.broken_auth');
    });

    test('rejects a configuration with no CA', () {
      final text = '''
client
dev tun
remote 1.2.3.4 1194
cipher AES-256-GCM
''';
      final parsed = OvpnParser.parse(text).valueOr;
      final verdict = OvpnValidator.validate(parsed);
      expect(verdict.isOk, isFalse);
      expect(verdict.errorOrNull?.code, 'ovpn.no_ca');
    });

    test('rejects route-nopull without pull', () {
      final text = withDirective('\nroute-nopull');
      final parsed = OvpnParser.parse(text).valueOr;
      final verdict = OvpnValidator.validate(parsed);
      expect(verdict.isOk, isFalse);
      expect(verdict.errorOrNull?.code, 'ovpn.route_nopull');
    });

    test('rejects a layer 2 tap device', () {
      final text = baseConfig().replaceFirst('dev tun', 'dev tap');
      final parsed = OvpnParser.parse(text).valueOr;
      final verdict = OvpnValidator.validate(parsed);
      expect(verdict.isOk, isFalse);
      expect(verdict.errorOrNull?.code, 'ovpn.tap_unsupported');
    });

    test('records a repair for missing routing directives', () {
      final parsed = OvpnParser.parse(baseConfig()).valueOr;
      final verdict = OvpnValidator.validate(parsed).valueOr;
      expect(verdict.repairs, isNotEmpty);
      expect(verdict.repairs.any((r) => r.contains('pull')), isTrue);
      expect(
        verdict.repairs.any((r) => r.contains('redirect-gateway')),
        isTrue,
      );
    });
  });

  group('OvpnSerializer', () {
    test('preserves server authentication, TLS and remote transport', () {
      final profile =
          '''
${baseConfig().replaceFirst('remote vpn.example.net 1194', 'remote vpn.example.net 443 tcp-client')}
key-direction 1
tls-version-min 1.2
tls-cert-profile preferred
verify-x509-name vpn.example.net name
data-ciphers AES-256-GCM:AES-128-GCM
data-ciphers-fallback AES-128-CBC
''';
      final parsed = OvpnParser.parse(profile).valueOr;
      final verdict = OvpnValidator.validate(parsed);
      expect(verdict.isOk, isTrue);
      final out = OvpnSerializer.serialize(verdict.valueOr.config);
      for (final line in [
        'remote-cert-tls server',
        'remote vpn.example.net 443 tcp-client',
        'key-direction 1',
        'tls-version-min 1.2',
        'tls-cert-profile preferred',
        'verify-x509-name vpn.example.net name',
        'data-ciphers AES-256-GCM:AES-128-GCM',
        'data-ciphers-fallback AES-128-CBC',
      ]) {
        expect(out, contains('$line\n'));
      }
    });

    test('a live-feed row survives validation and serialisation intact', () {
      // The shape of a real VPN Gate row as published (TCP variant):
      // no pull, no redirect-gateway, commented-out auth-user-pass,
      // inline trust material. Certificate *contents* are deliberately
      // stubbed here — their validity is checked against the live feed
      // in the verification report, not in this unit test.
      const text = '''
client
dev tun
proto tcp
remote 203.0.113.7 443
cipher AES-128-CBC
data-ciphers AES-128-CBC
auth SHA1
resolv-retry infinite
nobind
persist-key
persist-tun
verb 3
#auth-user-pass
<ca>
-----BEGIN CERTIFICATE-----
QUJD
-----END CERTIFICATE-----
</ca>
<cert>
-----BEGIN CERTIFICATE-----
REVG
-----END CERTIFICATE-----
</cert>
<key>
-----BEGIN PRIVATE KEY-----
SElK
-----END PRIVATE KEY-----
</key>
''';
      final parsed = OvpnParser.parse(text).valueOr;
      final verdict = OvpnValidator.validate(parsed);
      expect(verdict.isOk, isTrue, reason: '${verdict.errorOrNull}');
      final out = OvpnSerializer.serialize(verdict.valueOr.config);

      // Everything the handshake needs is still there, addressed to
      // the same server.
      for (final line in [
        'proto tcp',
        'remote 203.0.113.7 443',
        'data-ciphers AES-128-CBC',
        'auth SHA1',
        '<ca>',
        '<cert>',
        '<key>',
      ]) {
        expect(out, contains(line), reason: 'lost in serialisation: $line');
      }
      // The full-tunnel normalisation the engine relies on.
      expect(out, contains('redirect-gateway def1'));
      // Nothing the validator refused may reappear, and a bare
      // auth-user-pass (a prompt the engine cannot answer) is never
      // emitted for a row that commented it out.
      expect(out, isNot(contains('auth-user-pass')));
      expect(out, isNot(contains('script-security')));
      expect(out, isNot(contains('plugin ')));
    });
  });
}
