import 'package:phantrix_core/src/logging/fingerprint.dart';
import 'package:phantrix_core/src/logging/redactor.dart';
import 'package:test/test.dart';

void main() {
	group('fingerprint', () {
		test('is stable for the same input', () {
			expect(fingerprintHex('hunter2'), fingerprintHex('hunter2'));
		});

		test('differs for different inputs', () {
			expect(fingerprintHex('hunter2'), isNot(fingerprintHex('hunter3')));
		});

		test('handles an empty string', () {
			expect(fingerprintHex(''), hasLength(8));
		});

		test('handles multi-byte input', () {
			expect(fingerprintHex('مفتاح سري'), hasLength(8));
		});

		test('uses only web-safe integer sizes', () {
			// The regression this guards: a 64-bit literal breaks the web build.
			// Assert the result fits in 32 bits, which is what the halving
			// arithmetic guarantees.
			expect(stableFingerprint('anything at all'), lessThan(0x100000000));
		});

		test('a long input does not overflow into a negative value', () {
			final long = 'a' * 10000;
			expect(stableFingerprint(long), greaterThanOrEqualTo(0));
		});
	});

	group('Redactor after the hash rewrite', () {
		test('still removes a WireGuard private key', () {
			const key = '02R31BtVMJe/5r8cMd8uRVf6DysDrWKFXxDlMdRDU6c=';
			final out = Redactor.redact('PrivateKey = $key');
			expect(out, isNot(contains(key)));
			expect(out, contains('[redacted-'));
		});

		test('the same key produces the same marker', () {
			const key = '02R31BtVMJe/5r8cMd8uRVf6DysDrWKFXxDlMdRDU6c=';
			expect(Redactor.fingerprint(key), Redactor.fingerprint(key));
		});

		test('two different keys produce different markers', () {
			expect(
				Redactor.fingerprint('02R31BtVMJe/5r8cMd8uRVf6DysDrWKFXxDlMdRDU6c='),
				isNot(Redactor.fingerprint('iGaPncC709q7zIxUD9OMJENN3dh+W40oQx0Lv7AStp8=')),
			);
		});
	});
}
