import 'dart:convert';
import 'package:phantrix_core/src/core/app_error.dart';
import 'package:phantrix_core/src/core/result.dart';
import 'package:phantrix_core/src/model/logging_policy.dart';
import 'package:phantrix_core/src/model/server_status.dart';
import 'package:phantrix_core/src/model/trust_level.dart';
import 'package:phantrix_core/src/protocol/protocol_kind.dart';
import 'package:phantrix_core/src/providers/common/http_fetcher.dart';
import 'package:phantrix_core/src/providers/vpn_gate/vpn_gate_profile_cache.dart';
import 'package:phantrix_core/src/providers/vpn_gate/vpn_gate_provider.dart';
import 'package:phantrix_core/src/providers/vpn_gate/vpn_gate_row.dart';
import 'package:test/test.dart';


/// A minimal OpenVPN configuration that actually passes `OvpnValidator`: one
/// remote, an inline CA and no directive the engine refuses to act on.
///
/// Real VPN Gate rows carry a full client profile; only the parts that the
/// parser and the security policy look at are reproduced here.
const String kRelayConfigText = '''
client
dev tun
proto udp
remote public-relay.example.net 1194
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
cipher AES-256-GCM
auth SHA256

<ca>
-----BEGIN CERTIFICATE-----
MIIFazCCA1OgAwIBAgIRAIIQz7DSQONZRGPgu2OCiwAwDQYJKoZIhvcNAQELBQAw
TzELMAkGA1UEBhMCVVMxKTAnBgNVBAoTIEludGVybmV0IFNlY3VyaXR5IFJlc2Vh
-----END CERTIFICATE-----
</ca>
''';

/// The 15 columns the feed publishes, in the documented order.
///
/// See <https://www.vpngate.net/api/iphone/>.
const List<String> kHeaderFields = [
	'HostName',
	'IP',
	'Score',
	'Ping',
	'Speed',
	'CountryLong',
	'CountryShort',
	'NumVpnSessions',
	'Uptime',
	'TotalUsers',
	'TotalTraffic',
	'LogType',
	'Operator',
	'Message',
	'OpenVPN_ConfigData_Base64',
];

/// A config the validator rejects: it asks OpenVPN to run a program.
const String kDangerousConfigText = '''
client
dev tun
proto udp
remote public-relay.example.net 1194
cipher AES-256-GCM
up /bin/sh -c "id"

<ca>
-----BEGIN CERTIFICATE-----
MIIFazCCA1OgAwIBAgIRAIIQz7DSQONZRGPgu2OCiwAwDQYJKoZIhvcNAQELBQAw
TzELMAkGA1UEBhMCVVMxKTAnBgNVBAoTIEludGVybmV0IFNlY3VyaXR5IFJlc2Vh
-----END CERTIFICATE-----
</ca>
''';

String encodeConfig(String text) => base64.encode(utf8.encode(text));

/// Builds one feed row with the documented field order. Columns the parser
/// does not map are filled with plausible filler values.
String feedRow({
	required String hostName,
	required String ip,
	required int score,
	required int ping,
	required int speed,
	required String countryLong,
	required String countryShort,
	required int sessions,
	required int uptimeSeconds,
	required int totalUsers,
	required int totalTraffic,
	required String logType,
	required String operator,
	required String message,
	required String configBase64,
}) =>
	[
		hostName,
		ip,
		'$score',
		'$ping',
		'$speed',
		countryLong,
		countryShort,
		'$sessions',
		'$uptimeSeconds',
		'$totalUsers',
		'$totalTraffic',
		logType,
		operator,
		message,
		configBase64,
	].join(',');

String vpnGateRow({
	required String hostName,
	required String ip,
	required String countryLong,
	required String countryShort,
	required String configBase64,
	String logType = '2weeks',
	String operator = 'Some volunteer',
	String message = '',
	int score = 500000,
	int ping = 120,
	int sessions = 40,
	int uptimeSeconds = 2592000,
}) =>
	feedRow(
		hostName: hostName,
		ip: ip,
		score: score,
		ping: ping,
		speed: 98765432,
		countryLong: countryLong,
		countryShort: countryShort,
		sessions: sessions,
		uptimeSeconds: uptimeSeconds,
		totalUsers: 300,
		totalTraffic: 1234567890,
		logType: logType,
		operator: operator,
		message: message,
		configBase64: configBase64,
	);

/// Wraps [rows] in the feed envelope: the `*vpn_servers` banner, the `#`
/// header line and the `*` trailer.
String feed(List<String> rows) {
	final buffer = StringBuffer()
		..writeln('*vpn_servers')
		..writeln('#${kHeaderFields.join(',')}');
	for (final row in rows) {
		buffer.writeln(row);
	}
	buffer.write('*');
	return buffer.toString();
}

/// A transport that always answers with [body] and never fails.
class _FakeFetcher implements HttpFetcher {
	_FakeFetcher(this.body);

	final String body;

	final List<Uri> requested = <Uri>[];

	@override
	Future<String> get(Uri url) async {
		requested.add(url);
		return body;
	}

	@override
	int get maxBodyBytes => 1024 * 1024;
}

void main() {
	group('VpnGateParser', () {
		test('parses a realistic 15-column feed', () {
			final body = feed([
				vpnGateRow(
					hostName: 'public-relay-001.example.net',
					ip: '203.0.113.10',
					countryLong: 'Japan',
					countryShort: 'jp',
					configBase64: encodeConfig(kRelayConfigText),
					message: 'Operated by a volunteer in Tokyo',
				),
				vpnGateRow(
					hostName: 'public-relay-002.example.net',
					ip: '198.51.100.20',
					countryLong: 'United States',
					countryShort: 'US',
					configBase64: encodeConfig(kRelayConfigText),
					operator: 'Other volunteer (Berlin)',
				),
				vpnGateRow(
					hostName: 'public-relay-003.example.net',
					ip: '192.0.2.30',
					countryLong: 'Brazil',
					countryShort: 'BR',
					configBase64: encodeConfig(kRelayConfigText),
					logType: 'none',
				),
			]);

			final result = VpnGateParser.parse(body);
			expect(result, isA<Ok<List<VpnGateRow>>>());
			expect(result.isOk, isTrue);

			final rows = result.valueOr;
			expect(rows, hasLength(3));

			final first = rows.first;
			expect(first.hostName, 'public-relay-001.example.net');
			expect(first.ip, '203.0.113.10');
			expect(first.ping, 120);
			expect(first.score, 500000);
			expect(first.sessions, 40);
			expect(first.uptimeSeconds, 2592000);
			expect(first.totalUsers, 300);
			expect(first.countryLong, 'Japan');
			expect(first.countryShort, 'jp');
			expect(first.logType, '2weeks');
			expect(first.operator, 'Some volunteer');
			expect(first.message, 'Operated by a volunteer in Tokyo');
			expect(first.uptimeRatio, closeTo(1, 0.0001));
			expect(first.countryCode, 'JP');

			// The country code is normalised regardless of the feed's casing.
			expect(rows[1].countryCode, 'US');
			expect(rows[2].countryCode, 'BR');
			expect(
				rows.map((r) => r.countryCode),
				['JP', 'US', 'BR'],
			);
		});

		test('base64-decodes the config column back into the original text', () {
			final body = feed([
				vpnGateRow(
					hostName: 'public-relay-001.example.net',
					ip: '203.0.113.10',
					countryLong: 'Japan',
					countryShort: 'JP',
					configBase64: encodeConfig(kRelayConfigText),
				),
			]);

			final row = VpnGateParser.parse(body).valueOr.single;
			expect(row.configBase64, isNotEmpty);
			expect(row.config, kRelayConfigText);
		});

		test('returns a row with no config when the column is not base64', () {
			final body = feed([
				vpnGateRow(
					hostName: 'public-relay-broken.example.net',
					ip: '203.0.113.11',
					countryLong: 'Japan',
					countryShort: 'JP',
					configBase64: '%%%not-base64%%%',
				),
			]);

			final result = VpnGateParser.parse(body);
			expect(result.isOk, isTrue);
			// The parser is a raw row parse: it does not judge the payload.
			final rows = result.valueOr;
			expect(rows, hasLength(1));
			expect(rows.first.hostName, 'public-relay-broken.example.net');
			expect(rows.first.config, isNull);
		});

		test('keeps a row whose config column is empty', () {
			final body = feed([
				vpnGateRow(
					hostName: 'public-relay-empty.example.net',
					ip: '203.0.113.12',
					countryLong: 'Japan',
					countryShort: 'JP',
					configBase64: '',
				),
			]);

			final rows = VpnGateParser.parse(body).valueOr;
			expect(rows, hasLength(1));
			expect(rows.single.config, isNull);
		});

		test('skips the banner, the header and the trailer', () {
			final body = feed([
				vpnGateRow(
					hostName: 'public-relay-001.example.net',
					ip: '203.0.113.10',
					countryLong: 'Japan',
					countryShort: 'JP',
					configBase64: encodeConfig(kRelayConfigText),
				),
			]);

			final lines = const LineSplitter().convert(body);
			expect(lines.first.startsWith('*'), isTrue);
			expect(lines[1].startsWith('#'), isTrue);
			expect(lines.last.startsWith('*'), isTrue);

			final rows = VpnGateParser.parse(body).valueOr;
			expect(rows, hasLength(1));
		});

		test('ignores blank lines and rows with too few fields', () {
			final body = feed([
				'',
				'   ',
				'only,four,fields',
				vpnGateRow(
					hostName: 'public-relay-001.example.net',
					ip: '203.0.113.10',
					countryLong: 'Japan',
					countryShort: 'JP',
					configBase64: encodeConfig(kRelayConfigText),
				),
			]);

			final rows = VpnGateParser.parse(body).valueOr;
			expect(rows, hasLength(1));
		});

		test('returns an error for an empty body', () {
			final result = VpnGateParser.parse('');
			expect(result, isA<Err<List<VpnGateRow>>>());
			expect(result.isOk, isFalse);
			expect(result.errorOrNull?.code, 'vpn_gate.empty');
		});

		test('returns an error for a body with only the feed envelope', () {
			final result = VpnGateParser.parse('*vpn_servers\n#HostName\n*');
			expect(result.isOk, isFalse);
			expect(result.errorOrNull?.code, 'vpn_gate.empty');
		});
	});

	group('VpnGateParser.loggingFor', () {
		test('reads the operator-claimed logging policy from the log type', () {
			expect(LoggingPolicy.fromVpnGate('2weeks'), LoggingPolicy.twoWeeks);
			expect(LoggingPolicy.fromVpnGate('none'), LoggingPolicy.noneClaimed);
			expect(LoggingPolicy.fromVpnGate(null), LoggingPolicy.unknown);
			expect(LoggingPolicy.fromVpnGate('unknown'), LoggingPolicy.other);
		});

		test('is case-insensitive and understands the 30-day spelling', () {
			expect(LoggingPolicy.fromVpnGate('2Weeks'), LoggingPolicy.twoWeeks);
			expect(LoggingPolicy.fromVpnGate('nologs'), LoggingPolicy.noneClaimed);
			expect(LoggingPolicy.fromVpnGate('1month'), LoggingPolicy.thirtyDays);
		});
	});

	group('VpnGateParser.statusFor', () {
		test('maps a ping onto a status', () {
			VpnGateRow rowAt(int ping) => VpnGateRow(
				hostName: 'r.example.net',
				ip: '203.0.113.10',
				score: 1,
				ping: ping,
				countryLong: 'Japan',
				countryShort: 'JP',
				sessions: 1,
				uptimeSeconds: 1000,
				totalUsers: 1,
				logType: '2weeks',
				operator: '',
				message: '',
				configBase64: encodeConfig(kRelayConfigText),
			);

			expect(VpnGateParser.statusFor(rowAt(120)), ServerStatus.online);
			expect(VpnGateParser.statusFor(rowAt(450)), ServerStatus.degraded);
			expect(VpnGateParser.statusFor(rowAt(0)), ServerStatus.offline);
			expect(VpnGateParser.statusFor(rowAt(-1)), ServerStatus.offline);
			expect(VpnGateParser.statusFor(rowAt(9000)), ServerStatus.offline);
			expect(VpnGateParser.loggingFor(rowAt(120)), LoggingPolicy.twoWeeks);
		});
	});

	group('VpnGateProvider', () {
		test('publishes metadata quickly but only supplies validated profiles', () async {
			final body = feed([
				vpnGateRow(
					hostName: 'good.example.net',
					ip: '203.0.113.10',
					countryLong: 'Japan',
					countryShort: 'JP',
					configBase64: encodeConfig(kRelayConfigText),
				),
				// Metadata is cheap to publish, but its profile must still be
				// rejected before it can ever reach a tunnel.
				vpnGateRow(
					hostName: 'dangerous.example.net',
					ip: '203.0.113.11',
					countryLong: 'Japan',
					countryShort: 'JP',
					configBase64: encodeConfig(kDangerousConfigText),
				),
				// This malformed profile is likewise rejected when requested.
				vpnGateRow(
					hostName: 'broken.example.net',
					ip: '203.0.113.12',
					countryLong: 'Japan',
					countryShort: 'JP',
					configBase64: '%%%not-base64%%%',
				),
			]);

			final provider = VpnGateProvider(fetcher: _FakeFetcher(body));
			final outcome = await provider.refresh();

			expect(outcome.isOk, isTrue);
			expect(outcome.usedCache, isFalse);
			expect(outcome.fetchedAt, isNotNull);
			expect(outcome.servers, hasLength(3));

			final server = outcome.servers.firstWhere((item) => item.id == 'good.example.net');
			expect(server.id, 'good.example.net');
			expect(server.hostname, 'good.example.net');
			expect(server.hostAddress, '203.0.113.10');
			expect(server.protocol, ProtocolKind.openVpn);
			expect(server.providerId, 'vpngate');
			expect(server.countryCode, 'JP');
			expect(server.trustLevel, TrustLevel.publicRelay);
			expect(server.trustLevel.requiresWarning, isTrue);
			expect(server.metrics.latencyMs, 120);
			expect(server.metrics.score, 500000);
			expect(server.metrics.activeUsers, 40);
			expect(server.loggingPolicy, LoggingPolicy.twoWeeks);
			expect(server.notes, contains('Operator states logging policy: 2weeks'));
		});

		test('serves a validated config for an accepted server only', () async {
			final body = feed([
				vpnGateRow(
					hostName: 'good.example.net',
					ip: '203.0.113.10',
					countryLong: 'Japan',
					countryShort: 'JP',
					configBase64: encodeConfig(kRelayConfigText),
				),
				vpnGateRow(
					hostName: 'dangerous.example.net',
					ip: '203.0.113.11',
					countryLong: 'Japan',
					countryShort: 'JP',
					configBase64: encodeConfig(kDangerousConfigText),
				),
			]);

			final provider = VpnGateProvider(fetcher: _FakeFetcher(body));
			await provider.refresh();

			final config = await provider.fetchConfig('good.example.net');
			expect(config, isNotNull);
			expect(config!.providerId, 'vpngate');
			expect(config.rawText, kRelayConfigText);
			expect(config.validated.kind, ProtocolKind.openVpn);
			expect(config.requiresCredentials, isFalse);

			expect(await provider.fetchConfig('dangerous.example.net'), isNull);
			expect(await provider.fetchConfig('broken.example.net'), isNull);
			expect(await provider.fetchConfig('never-seen.example.net'), isNull);
		});

		test('reuses the in-memory catalog within the short cache TTL', () async {
			final fetcher = _FakeFetcher(feed([
				vpnGateRow(
					hostName: 'relay.example.net',
					ip: '203.0.113.10',
					countryLong: 'Japan',
					countryShort: 'JP',
					configBase64: encodeConfig(kRelayConfigText),
				),
			]));
			final provider = VpnGateProvider(fetcher: fetcher);

			final first = await provider.refresh();
			final second = await provider.refresh();
			final forced = await provider.refresh(force: true);

			expect(first.usedCache, isFalse);
			expect(second.usedCache, isTrue);
			expect(second.fetchedAt, first.fetchedAt);
			expect(second.servers, hasLength(1));
			expect(forced.usedCache, isFalse);
			expect(fetcher.requested, hasLength(2));
		});

		test('refreshes on demand when cached metadata has no saved profile', () async {
			final fetcher = _FakeFetcher(feed([
				vpnGateRow(
					hostName: 'legacy.example.net',
					ip: '203.0.113.21',
					countryLong: 'Japan',
					countryShort: 'JP',
					configBase64: encodeConfig(kRelayConfigText),
				),
			]));
			final provider = VpnGateProvider(fetcher: fetcher);

			// Simulates an older installation that has directory metadata but did
			// not persist the matching OpenVPN profile. It should recover on the
			// first connection attempt instead of permanently failing selection.
			final config = await provider.fetchConfig('legacy.example.net');
			expect(config, isNotNull);
			expect(fetcher.requested, hasLength(1));
			expect(config!.validated.kind, ProtocolKind.openVpn);
		});

		test('uses a saved profile when the feed is unavailable after restart', () async {
			final profileCache = MemoryVpnGateProfileCache();
			final body = feed([
				vpnGateRow(
					hostName: 'saved.example.net',
					ip: '203.0.113.20',
					countryLong: 'Japan',
					countryShort: 'JP',
					configBase64: encodeConfig(kRelayConfigText),
				),
			]);
			final firstProvider = VpnGateProvider(
				fetcher: _FakeFetcher(body),
				profileCache: profileCache,
			);
			final firstRefresh = await firstProvider.refresh();
			expect(firstRefresh.isOk, isTrue);

			// A new provider instance simulates an app restart. The live feed then
			// fails, but a selected cached profile is still re-validated on demand.
			final restartedProvider = VpnGateProvider(
				fetcher: _BrokenFetcher(
					const AppError(
						group: ErrorGroup.network,
						code: 'network.offline',
						message: 'The feed is temporarily unavailable.',
					),
				),
				profileCache: profileCache,
			);
			final failedRefresh = await restartedProvider.refresh();
			expect(failedRefresh.isOk, isFalse);
			final config = await restartedProvider.fetchConfig('saved.example.net');
			expect(config, isNotNull);
			expect(config!.validated.kind, ProtocolKind.openVpn);
		});

		test('reports the feed endpoint and its trust description', () async {
			final provider = VpnGateProvider(fetcher: _FakeFetcher(''));
			expect(provider.endpoint.toString(), 'https://www.vpngate.net/api/iphone/');
			expect(provider.id, 'vpngate');
			expect(provider.capabilities.protocols, {ProtocolKind.openVpn});
			expect(provider.autoRefresh, isTrue);
			expect(provider.trustDescription, contains('volunteer'));
		});

		test('turns a transport failure into a failed refresh', () async {
			final provider = VpnGateProvider(
				fetcher: _BrokenFetcher(
					const AppError(
						group: ErrorGroup.network,
						code: 'network.offline',
						message: 'The device is offline.',
					),
				),
			);

			final outcome = await provider.refresh();
			expect(outcome.isOk, isFalse);
			expect(outcome.servers, isEmpty);
			expect(outcome.error?.code, 'network.offline');
		});

		test('turns an empty feed into a failed refresh', () async {
			final provider = VpnGateProvider(fetcher: _FakeFetcher(''));
			final outcome = await provider.refresh();
			expect(outcome.isOk, isFalse);
			expect(outcome.error?.code, 'vpn_gate.empty');
		});
	});
}

/// A transport that always fails the way the real one is documented to.
class _BrokenFetcher implements HttpFetcher {
	_BrokenFetcher(this.error);

	final AppError error;

	@override
	Future<String> get(Uri url) async => throw error;

	@override
	int get maxBodyBytes => 1024 * 1024;
}
