import 'package:phantrix_core/src/protocol/address_cidr.dart';
import 'package:test/test.dart';

/// Regression tests for two parsing holes.
///
/// `parse` enforced only the upper bound of the prefix range, so a negative
/// prefix (`10.0.0.2/-1`) was accepted with an error message that claimed the
/// range was "between 0 and 32". And `isIpv6` rejected two separate `::` but
/// not a run of three or more colons, so `:::` was read as an address.
void main() {
  group('AddressCidr.parse', () {
    test('rejects a negative prefix length', () {
      expect(AddressCidr.parse('10.0.0.2/-1').isOk, isFalse);
      expect(AddressCidr.parse('fd42::1/-1').isOk, isFalse);
    });

    test('accepts the smallest and largest valid prefixes', () {
      expect(AddressCidr.parse('10.0.0.0/0').isOk, isTrue);
      expect(AddressCidr.parse('10.0.0.2/32').isOk, isTrue);
      expect(AddressCidr.parse('fd42::/0').isOk, isTrue);
      expect(AddressCidr.parse('fd42::1/128').isOk, isTrue);
    });

    test('rejects a prefix beyond the family maximum', () {
      expect(AddressCidr.parse('10.0.0.2/33').isOk, isFalse);
      expect(AddressCidr.parse('fd42::1/129').isOk, isFalse);
    });
  });

  group('AddressCidr.isIpv6', () {
    test('rejects a single leading or trailing colon', () {
      expect(AddressCidr.isIpv6(':1:2:3:4:5:6:7:8'), isFalse);
      expect(AddressCidr.isIpv6('1:2:3:4:5:6:7:8:'), isFalse);
    });

    test('accepts IPv4-mapped IPv6 and keeps its family', () {
      expect(AddressCidr.isIpv6('::ffff:192.0.2.1'), isTrue);
      final address = AddressCidr.parse('::ffff:192.0.2.1/128').valueOrNull!;
      expect(address.isV6, isTrue);
      expect(address.isV4, isFalse);
    });

    test('rejects a run of three or more colons', () {
      expect(AddressCidr.isIpv6(':::'), isFalse);
      expect(AddressCidr.isIpv6('1:::2'), isFalse);
    });

    test('accepts the compressed forms', () {
      expect(AddressCidr.isIpv6('::'), isTrue);
      expect(AddressCidr.isIpv6('::1'), isTrue);
      expect(AddressCidr.isIpv6('fd42::1'), isTrue);
    });

    test('rejects a bare single colon', () {
      expect(AddressCidr.isIpv6(':'), isFalse);
    });
  });

  test('IPv4 octets must be unambiguous decimal digits', () {
    for (final value in ['+1.2.3.4', '1. 2.3.4', '01.2.3.4', '256.2.3.4']) {
      expect(AddressCidr.isIpv4(value), isFalse, reason: value);
    }
  });
}
