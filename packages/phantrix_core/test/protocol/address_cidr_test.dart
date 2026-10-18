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
}
