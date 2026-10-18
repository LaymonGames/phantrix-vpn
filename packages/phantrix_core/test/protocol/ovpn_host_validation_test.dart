import 'package:phantrix_core/phantrix_core.dart';
import 'package:test/test.dart';

/// Host validation in the OpenVPN validator.
///
/// These exist because a real defect was found here: `_validHost` asked a
/// regular expression for capture groups 1 through 4 when the pattern
/// defines only one, so *every* OpenVPN configuration with an IPv4 remote
/// threw a `RangeError` instead of validating. That made the most common
/// case in the wild unusable, and it crashed rather than returning an error.
void main() {
  const ca = '''
-----BEGIN CERTIFICATE-----
MIIFazCCA1OgAwIBAgIRAIIQz7DSQONZRGPgu2OCiwAwDQYJKoZIhvcNAQELBQAw
TzELMAkGA1UEBhMCVVMxKTAnBgNVBAoTIEludGVybmV0IFNlY3VyaXR5IFJlc2Vh
-----END CERTIFICATE-----
''';

  String ovpnWith(String remote) =>
      '''
client
dev tun
proto udp
remote $remote 1194
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
verb 3
<ca>
$ca
</ca>
''';

  group('an IPv4 remote must validate, not crash', () {
    test('a normal public address is accepted', () {
      final parsed = OvpnParser.parse(ovpnWith('192.0.2.1')).valueOrNull!;
      // The regression: this threw RangeError before.
      final result = OvpnValidator.validate(parsed);
      expect(result, isA<Ok<OvpnVerdict>>());
    });

    test('a fully specified address is accepted', () {
      final parsed = OvpnParser.parse(ovpnWith('8.8.8.8')).valueOrNull!;
      expect(OvpnValidator.validate(parsed), isA<Ok<OvpnVerdict>>());
    });

    test('each octet is actually range-checked', () {
      // 256 is out of range, so this must be rejected rather than
      // accepted because the regex merely *shaped* like an address.
      final parsed = OvpnParser.parse(ovpnWith('192.0.2.256')).valueOrNull!;
      expect(OvpnValidator.validate(parsed), isA<Err<OvpnVerdict>>());
    });

    test('a hostname is still accepted', () {
      final parsed = OvpnParser.parse(ovpnWith('vpn.example.com')).valueOrNull!;
      expect(OvpnValidator.validate(parsed), isA<Ok<OvpnVerdict>>());
    });

    test('an IPv6 literal is still accepted', () {
      final parsed = OvpnParser.parse(ovpnWith('2001:db8::1')).valueOrNull!;
      expect(OvpnValidator.validate(parsed), isA<Ok<OvpnVerdict>>());
    });

    test('a nonsense host is rejected without throwing', () {
      for (final bad in ['not a host', '999.999.999.999', '..', 'a..b']) {
        final parsed = OvpnParser.parse(ovpnWith(bad)).valueOrNull;
        if (parsed == null) {
          continue; // the parser rejected it, which is also fine
        }
        expect(
          OvpnValidator.validate(parsed),
          isA<Err<OvpnVerdict>>(),
          reason: 'accepted an invalid host: $bad',
        );
      }
    });
  });

  group('a DNS name is accepted when it is well formed', () {
    // These are the shapes VPN Gate and most commercial providers actually
    // publish. Rejecting any of them would make a working configuration
    // unusable, which is the opposite of what a validator is for.
    for (final host in [
      'vpn.example.com',
      'de-01.provider.net',
      'a.b.c.d.example.org',
      'xn--wg-0na.example', // a punycode label
      'vpn-us-east-01.example.com', // hyphens in the middle of a label
      'vpn_gate.example.com', // an underscore occurs in real records
    ]) {
      test('accepts $host', () {
        final parsed = OvpnParser.parse(ovpnWith(host)).valueOrNull!;
        expect(
          OvpnValidator.validate(parsed),
          isA<Ok<OvpnVerdict>>(),
          reason: 'rejected a well-formed hostname: $host',
        );
      });
    }
  });

  group('a DNS name the validator deliberately refuses', () {
    // Stricter than DNS, on purpose. Each of these is a legal DNS name but
    // a poor VPN remote, and refusing them is the safe direction: a config
    // that is rejected is shown to the user with a reason, whereas a config
    // that is accepted and then cannot be reached leaves the user believing
    // the client is broken.
    for (final host in [
      'single-host', // no dot: not a public server name
      'vpn.example.com.', // a trailing dot, the fully qualified form
    ]) {
      test('refuses $host', () {
        final parsed = OvpnParser.parse(ovpnWith(host)).valueOrNull!;
        expect(
          OvpnValidator.validate(parsed),
          isA<Err<OvpnVerdict>>(),
          reason: 'accepted a form the validator should refuse: $host',
        );
      });
    }
  });

  group('an IPv6 remote is accepted in the forms that occur', () {
    // IPv6 literals appear unbracketed in `remote` lines, which is what the
    // validator has to cope with.
    for (final host in [
      '2001:db8::1',
      '2001:0db8:0000:0000:0000:0000:0000:0001',
      '::1',
    ]) {
      test('accepts $host', () {
        final parsed = OvpnParser.parse(ovpnWith(host)).valueOrNull!;
        expect(
          OvpnValidator.validate(parsed),
          isA<Ok<OvpnVerdict>>(),
          reason: 'rejected a valid IPv6 remote: $host',
        );
      });
    }

    test('a zone index is refused', () {
      // `fe80::1%eth0` is a legal link-local address but not a remote VPN
      // server, and the '%' is not address syntax the parser accepts.
      final parsed = OvpnParser.parse(ovpnWith('fe80::1%eth0')).valueOrNull;
      if (parsed != null) {
        expect(OvpnValidator.validate(parsed), isA<Err<OvpnVerdict>>());
      }
    });
  });

  group('a malformed host is rejected, not guessed at', () {
    // Each of these is either not an address or not a hostname. Accepting
    // any of them means the app would go on to try to connect to something
    // that cannot exist.
    //
    // `-leading-hyphen` is the regression guard: the previous label pattern
    // was `[A-Za-z0-9_-]{1,63}`, which permits a leading hyphen, and a
    // hostname whose first label starts with a hyphen cannot resolve.
    for (final host in [
      '192.0.2.256',
      '192.0.2',
      'example..com',
      '-leading-hyphen.example.com',
      'trailing-hyphen-.example.com',
      'has space.example.com',
      'server;rm -rf /',
      // A command substitution inside what should be a hostname. The '$'
      // is escaped so the test's own source is never read as a Dart
      // interpolation, which would be an error at compile time.
      r'server \$(whoami).example.com',
    ]) {
      test('rejects $host', () {
        final parsed = OvpnParser.parse(ovpnWith(host)).valueOrNull;
        if (parsed == null) {
          return; // the parser already refused it
        }
        expect(
          OvpnValidator.validate(parsed),
          isA<Err<OvpnVerdict>>(),
          reason: 'accepted an invalid host: $host',
        );
      });
    }
  });

  group('a host split across lines is not a host', () {
    // A `remote` value containing a newline is not a single host. The
    // parser splits it, so the host that gets validated is the part before
    // the newline and the rest becomes a separate directive — which means
    // the test's expectation is about the host, not about the newline.
    test('only the first line is treated as the host', () {
      final parsed = OvpnParser.parse(
        ovpnWith('example.com\nPostUp /tmp/x'),
      ).valueOrNull;
      if (parsed != null) {
        expect(parsed.remotes.first.host, 'example.com');
      }
    });
  });
}
