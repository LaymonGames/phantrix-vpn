import 'package:phantrix_core/src/logging/redactor.dart';
import 'package:test/test.dart';

void main() {
  group('Redactor', () {
    test('prints a marker instead of a WireGuard private key', () {
      const key = '02R31BtVMJe/5r8cMd8uRVf6DysDrWKFXxDlMdRDU6c=';
      final out = Redactor.redact('handshake failed for PrivateKey = $key');
      // The base64 rule fingerprints the value first, and the credential
      // rule must leave that fingerprint alone rather than collapsing it.
      expect(out, isNot(contains(key)));
      expect(out, contains('[redacted-'));
    });

    test('collapses an OpenVPN inline certificate', () {
      final out = Redactor.redact('''
<ca>
-----BEGIN CERTIFICATE-----
MIIFazCCA1OgAwIBAgIRAIIQz7DSQONZRGPgu2OCiwAwDQYJKoZIhvcNAQEL
-----END CERTIFICATE-----
</ca>
''');
      expect(
        out,
        isNot(
          contains(
            'MIIFazCCA1OgAwIBAgIRAIIQz7DSQONZRGPgu2OCiwAwDQYJKoZIhvcNAQEL',
          ),
        ),
      );
      expect(out, contains('[redacted]'));
    });

    test('marks a password assignment without repeating the secret', () {
      final out = Redactor.redact('password=hunter2');
      // Absence, not just the marker's presence: the previous
      // implementation printed `hunter2: [redacted]`, which keeps the
      // secret it claims to remove. A test that only checks for the
      // marker passes on that output too, which is how the bug survived.
      expect(out, isNot(contains('hunter2')));
      expect(out, contains('password'));
      expect(out, contains('[redacted]'));
    });

    test('marks every credential form without repeating any secret', () {
      const cases = {
        'token: xyz-999': 'xyz-999',
        'username=alice, password=hunter2': 'alice',
        'PresharedKey = s3cr3t-value': 's3cr3t-value',
        'PrivateKey = short-but-realistic': 'short-but-realistic',
      };
      for (final entry in cases.entries) {
        final out = Redactor.redact(entry.key);
        expect(
          out,
          isNot(contains(entry.value)),
          reason: 'for input ${entry.key}',
        );
        expect(out, contains('[redacted]'), reason: 'for input ${entry.key}');
      }
      // The multi-assignment case must not leak the second secret either.
      expect(
        Redactor.redact('username=alice, password=hunter2'),
        isNot(contains('hunter2')),
      );
    });

    test(
      'leaves a filename reference alone, since the secret is not in it',
      () {
        // `auth-user-pass` in OpenVPN names a file; the credentials live in
        // that file, not on this line. There is no `=` or `:` assignment
        // here, so there is nothing to redact — and inventing a marker
        // would hide which file the line refers to.
        const line = 'auth-user-pass /etc/openvpn/login.conf';
        expect(Redactor.redact(line), line);
      },
    );

    test('drops the path and query from a URL', () {
      final out = Redactor.redact(
        'GET https://api.vpngate.net/iphone/?format=json failed',
      );
      expect(out, contains('https://api.vpngate.net'));
      expect(out, isNot(contains('format=json')));
    });

    test('keeps plain technical text', () {
      expect(
        Redactor.redact('WireGuard handshake failed: timeout'),
        'WireGuard handshake failed: timeout',
      );
    });
  });
}
