import 'package:phantrix_core/src/protocol/wireguard/wg_parser.dart';
import 'package:phantrix_core/src/protocol/wireguard/wg_serializer.dart';
import 'package:phantrix_core/src/protocol/wireguard/wg_validator.dart';
import 'package:test/test.dart';

const String kOldPriv2 = '02R31BtVMJe/5r8cMd8uRVf6DysDrWKFXxDlMdRDU6c=';
const String kOldPeer2 = 'iGaPncC709q7zIxUD9OMJENN3dh+W40oQx0Lv7AStp8=';

const String kValidConfig = '''
[Interface]
PrivateKey = 02R31BtVMJe/5r8cMd8uRVf6DysDrWKFXxDlMdRDU6c=
Address = 10.7.0.2/32
DNS = 10.7.0.1

[Peer]
PublicKey = iGaPncC709q7zIxUD9OMJENN3dh+W40oQx0Lv7AStp8=
AllowedIPs = 0.0.0.0/0
Endpoint = vpn.example.net:51820
PersistentKeepalive = 25
''';

void main() {
	group('WgParser', () {
		test('parses a full configuration', () {
			final result = WgParser.parse(kValidConfig);
			expect(result.isOk, isTrue);
			final config = result.valueOr;
			expect(config.interface.addresses, hasLength(1));
			expect(config.interface.addresses.first.address, '10.7.0.2');
			expect(config.interface.addresses.first.prefixLength, 32);
			expect(config.interface.dns, ['10.7.0.1']);
			expect(config.peers, hasLength(1));
			expect(config.peers.first.endpoint?.host, 'vpn.example.net');
			expect(config.peers.first.endpoint?.port, 51820);
			expect(config.peers.first.persistentKeepalive, 25);
			expect(config.isFullTunnel, isTrue);
			expect(config.supportsIpv6Route, isFalse);
		});

		test('accepts an IPv6 endpoints in brackets', () {
			final result = WgParser.parse('''
[Interface]
PrivateKey = 02R31BtVMJe/5r8cMd8uRVf6DysDrWKFXxDlMdRDU6c=
Address = fd42::2/128

[Peer]
PublicKey = iGaPncC709q7zIxUD9OMJENN3dh+W40oQx0Lv7AStp8=
AllowedIPs = ::/0
Endpoint = [2001:db8::1]:51820
''');
			expect(result.isOk, isTrue);
			expect(result.valueOr.peers.first.endpoint?.host, '2001:db8::1');
			expect(result.valueOr.supportsIpv6Route, isTrue);
		});

		test('rejects a missing private key', () {
			final result = WgParser.parse('''
[Interface]
Address = 10.7.0.2/32

[Peer]
PublicKey = iGaPncC709q7zIxUD9OMJENN3dh+W40oQx0Lv7AStp8=
AllowedIPs = 0.0.0.0/0
Endpoint = 1.2.3.4:51820
''');
			expect(result.isOk, isFalse);
			expect(result.errorOrNull?.code, 'wg.parse_failed');
		});

		test('rejects a wrong-length key', () {
			final result = WgParser.parse('''
[Interface]
PrivateKey = tooshort=
Address = 10.7.0.2/32

[Peer]
PublicKey = iGaPncC709q7zIxUD9OMJENN3dh+W40oQx0Lv7AStp8=
AllowedIPs = 0.0.0.0/0
Endpoint = 1.2.3.4:51820
''');
			expect(result.isOk, isFalse);
		});

		test('rejects an address with no prefix length', () {
			final result = WgParser.parse('''
[Interface]
PrivateKey = 02R31BtVMJe/5r8cMd8uRVf6DysDrWKFXxDlMdRDU6c=
Address = 10.7.0.2

[Peer]
PublicKey = iGaPncC709q7zIxUD9OMJENN3dh+W40oQx0Lv7AStp8=
AllowedIPs = 0.0.0.0/0
Endpoint = 1.2.3.4:51820
''');
			expect(result.isOk, isFalse);
			expect(result.errorOrNull?.code, 'wg.parse_failed');
		});

		test('records unknown directives but does not fail', () {
			final result = WgParser.parse('''
[Interface]
PrivateKey = 02R31BtVMJe/5r8cMd8uRVf6DysDrWKFXxDlMdRDU6c=
Address = 10.7.0.2/32
Bogus = 1

[Peer]
PublicKey = iGaPncC709q7zIxUD9OMJENN3dh+W40oQx0Lv7AStp8=
AllowedIPs = 0.0.0.0/0
Endpoint = 1.2.3.4:51820
''');
			expect(result.isOk, isTrue);
			expect(result.valueOr.unknownDirectives.containsKey('Interface.Bogus'), isTrue);
		});
	});

	group('WgValidator', () {
		test('rejects a configuration that runs commands', () {
			final parsed = WgParser.parse('''
[Interface]
PrivateKey = 02R31BtVMJe/5r8cMd8uRVf6DysDrWKFXxDlMdRDU6c=
Address = 10.7.0.2/32
Table = off

[Peer]
PublicKey = iGaPncC709q7zIxUD9OMJENN3dh+W40oQx0Lv7AStp8=
AllowedIPs = 0.0.0.0/0
Endpoint = 1.2.3.4:51820
''');
			expect(parsed.isOk, isTrue);
			final verdict = WgValidator.validate(parsed.valueOr);
			expect(verdict.isOk, isTrue);
			expect(verdict.valueOr.routeRepair, isFalse);
		});

		test('flags a missing default route and repairs it', () {
			final parsed = WgParser.parse('''
[Interface]
PrivateKey = 02R31BtVMJe/5r8cMd8uRVf6DysDrWKFXxDlMdRDU6c=
Address = 10.7.0.2/32

[Peer]
PublicKey = iGaPncC709q7zIxUD9OMJENN3dh+W40oQx0Lv7AStp8=
AllowedIPs = 10.7.0.0/24
Endpoint = 1.2.3.4:51820
''');
			expect(parsed.isOk, isTrue);
			final verdict = WgValidator.validate(parsed.valueOr);
			expect(verdict.isOk, isTrue);
			expect(verdict.valueOr.routeRepair, isTrue);
			final repaired = WgValidator.applyFullTunnel(parsed.valueOr);
			expect(repaired.peers.first.carriesDefaultRoute, isTrue);
			// The original object is untouched.
			expect(parsed.valueOr.peers.first.carriesDefaultRoute, isFalse);
		});

		test('rejects a peer with no endpoint', () {
			final parsed = WgParser.parse('''
[Interface]
PrivateKey = 02R31BtVMJe/5r8cMd8uRVf6DysDrWKFXxDlMdRDU6c=
Address = 10.7.0.2/32

[Peer]
PublicKey = iGaPncC709q7zIxUD9OMJENN3dh+W40oQx0Lv7AStp8=
AllowedIPs = 0.0.0.0/0
''');
			expect(parsed.isOk, isTrue);
			final verdict = WgValidator.validate(parsed.valueOr);
			expect(verdict.isOk, isFalse);
			expect(verdict.errorOrNull?.code, 'wg.peer.endpoint');
		});
	});

	group('WgSerializer', () {
		test('round-trips a configuration', () {
			final first = WgParser.parse(kValidConfig).valueOr;
			final text = WgSerializer.serialize(first);
			final second = WgParser.parse(text).valueOr;
			expect(WgSerializer.fingerprint(first), WgSerializer.fingerprint(second));
		});

		test('can omit the private key', () {
			final config = WgParser.parse(kValidConfig).valueOr;
			expect(
				WgSerializer.serialize(config, includePrivateKey: false),
				isNot(contains(config.interface.privateKey)),
			);
		});
	});
}
