import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:phantrix_core/phantrix_core.dart';
import 'package:phantrix/discovery/file_directory_cache.dart';
import 'package:phantrix/discovery/file_vpn_gate_profile_cache.dart';

void main() {
	group('FileDirectoryCache', () {
		late Directory directory;
		late FileDirectoryCache cache;

		setUp(() {
			directory = Directory.systemTemp.createTempSync('phantrix-directory-cache');
			cache = FileDirectoryCache.inDirectory(directory.path);
		});

		tearDown(() {
			if (directory.existsSync()) {
				directory.deleteSync(recursive: true);
			}
		});

		test('round-trips public metadata but not configuration material', () {
			final fetchedAt = DateTime.utc(2026, 10, 9, 12);
			cache.write([
				VpnServer(
					id: 'relay-hk-1',
					hostname: 'hk.example.test',
					hostAddress: '192.0.2.2',
					port: 51820,
					protocol: ProtocolKind.wireGuard,
					trustLevel: TrustLevel.imported,
					countryCode: 'HK',
					providerId: 'test',
					status: ServerStatus.online,
					metrics: const ServerMetrics(latencyMs: 32, activeUsers: 5),
				),
			], fetchedAt);

			final result = cache.read();
			expect(result, isA<Ok<CachedDirectory>>());
			final directory = (result as Ok<CachedDirectory>).value;
			expect(directory.fetchedAt.toUtc(), fetchedAt);
			expect(directory.servers, hasLength(1));
			expect(directory.servers.single.countryCode, 'HK');
			expect(directory.servers.single.metrics.latencyMs, 32);
			expect(cache.file.readAsStringSync(), isNot(contains('PrivateKey')));
		});

		test('normalizes cached ISO3 country codes to ISO2', () {
			cache.write([
				VpnServer(
					id: 'relay-hk-legacy',
					hostname: 'hk.example.test',
					hostAddress: '192.0.2.3',
					port: 1194,
					protocol: ProtocolKind.openVpn,
					trustLevel: TrustLevel.publicRelay,
					countryCode: 'HKG',
					providerId: 'legacy-feed',
				),
			], DateTime.utc(2026, 10, 9));

			final result = cache.read() as Ok<CachedDirectory>;
			expect(result.value.servers.single.countryCode, 'HK');
		});

		test('damaged cache is rejected instead of throwing', () {
			cache.file.parent.createSync(recursive: true);
			cache.file.writeAsStringSync('{bad json');
			expect(cache.read(), isA<Err<CachedDirectory>>());
		});
	});

	group('FileVpnGateProfileCache', () {
		late Directory directory;
		late FileVpnGateProfileCache cache;

		setUp(() {
			directory = Directory.systemTemp.createTempSync('phantrix-vpngate-profile-cache');
			cache = FileVpnGateProfileCache.inDirectory(directory.path);
		});

		tearDown(() {
			if (directory.existsSync()) {
				directory.deleteSync(recursive: true);
			}
		});

		test('persists only provider profile payloads and restores them', () {
			const profiles = {
				'relay.example.net': 'Y2xpZW50',
				'relay2.example.net': 'Y2xpZW50Mg==',
			};
			cache.write(profiles);
			expect(cache.read(), profiles);
			expect(cache.file.readAsStringSync(), contains('profiles'));
			expect(cache.file.readAsStringSync(), isNot(contains('PrivateKey')));
		});

		test('missing or corrupt profile cache is treated as empty', () {
			expect(cache.read(), isEmpty);
			cache.file.parent.createSync(recursive: true);
			cache.file.writeAsStringSync('{bad json');
			expect(cache.read(), isEmpty);
		});
	});
}
