import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:phantrix_core/src/core/app_error.dart';
import 'package:phantrix_core/src/model/trust_level.dart';
import 'package:phantrix_core/src/protocol/protocol_kind.dart';
import 'package:phantrix_core/src/providers/common/http_fetcher.dart';
import 'package:phantrix_core/src/providers/manifest/manifest_provider.dart';
import 'package:test/test.dart';


const String kPrivateKey = '02R31BtVMJe/5r8cMd8uRVf6DysDrWKFXxDlMdRDU6c=';
const String kPeerKey = 'iGaPncC709q7zIxUD9OMJENN3dh+W40oQx0Lv7AStp8=';

/// A full-tunnel WireGuard profile that survives parsing, validation, the
/// full-tunnel repair pass and re-validation.
const String kWireGuardConfig = '''
[Interface]
PrivateKey = $kPrivateKey
Address = 10.7.0.2/32
DNS = 10.7.0.1

[Peer]
PublicKey = $kPeerKey
AllowedIPs = 0.0.0.0/0
Endpoint = vpn1.example.org:51820
PersistentKeepalive = 25
''';

/// A profile the security policy refuses: `PostUp` runs a shell command.
const String kWireGuardWithPostUp = '''
[Interface]
PrivateKey = $kPrivateKey
Address = 10.7.0.2/32
PostUp = rm -rf /

[Peer]
PublicKey = $kPeerKey
AllowedIPs = 0.0.0.0/0
Endpoint = vpn1.example.org:51820
''';

const String kManifestUrl = 'https://servers.phantrix.example/manifest.json';

Map<String, Object?> serverEntry({
	required String id,
	required String hostname,
	required String country,
	String protocol = 'wireguard',
	List<String> endpoints = const ['vpn1.example.org:51820'],
	String? config,
	String? trust,
	String? city,
	double? latitude,
	double? longitude,
	String? operator,
	List<String>? notes,
}) =>
	{
		'id': id,
		'hostname': hostname,
		'country': country,
		'protocol': protocol,
		'endpoints': endpoints,
		'config': config ?? kWireGuardConfig,
		if (trust != null) 'trust': trust,
		if (city != null) 'city': city,
		if (latitude != null) 'latitude': latitude,
		if (longitude != null) 'longitude': longitude,
		if (operator != null) 'operator': operator,
		if (notes != null) 'notes': notes,
	};

String manifestJson(List<Map<String, Object?>> servers) =>
		jsonEncode({'version': 1, 'servers': servers});

/// A transport that answers from a fixed map of URL -> body.
class _FakeFetcher implements HttpFetcher {
	_FakeFetcher([this.bodies = const <String, String>{}]);

	final Map<String, String> bodies;

	final List<Uri> requested = <Uri>[];

	@override
	Future<String> get(Uri url) async {
		requested.add(url);
		final body = bodies[url.toString()];
		if (body == null) {
			throw const AppError(
				group: ErrorGroup.provider,
				code: 'test.no_fixture',
				message: 'The fake fetcher has no body for this URL.',
			);
		}
		return body;
	}

	@override
	int get maxBodyBytes => 1024 * 1024;
}

ManifestProvider providerFor(String body, {String? manifestUrl}) =>
		ManifestProvider(
			fetcher: _FakeFetcher({manifestUrl ?? kManifestUrl: body}),
			manifestUrl: manifestUrl ?? kManifestUrl,
		);

void main() {
	group('ManifestProvider.refresh', () {
		test('offers project-verified servers from a valid manifest', () async {
			final body = manifestJson([
				serverEntry(
					id: 'nl-1',
					hostname: 'vpn1.example.org',
					country: 'nl',
					trust: 'project',
					city: 'Amsterdam',
					latitude: 52.3676,
					longitude: 4.9041,
					operator: 'Phantrix Foundation',
					notes: ['Audited 2026-01'],
				),
				serverEntry(
					id: 'de-1',
					hostname: 'vpn2.example.org',
					country: 'DE',
					trust: 'project',
				),
			]);

			final outcome = await providerFor(body).refresh();

			expect(outcome.isOk, isTrue);
			expect(outcome.usedCache, isFalse);
			expect(outcome.fetchedAt, isNotNull);
			expect(outcome.servers, hasLength(2));

			final byId = {for (final s in outcome.servers) s.id: s};
			expect(byId.keys, containsAll(['nl-1', 'de-1']));

			final first = byId['nl-1']!;
			expect(first.hostname, 'vpn1.example.org');
			expect(first.countryCode, 'NL');
			expect(first.city, 'Amsterdam');
			expect(first.latitude, closeTo(52.3676, 0.0001));
			expect(first.longitude, closeTo(4.9041, 0.0001));
			expect(first.operatorName, 'Phantrix Foundation');
			expect(first.protocol, ProtocolKind.wireGuard);
			expect(first.providerId, 'manifest');
			expect(first.trustLevel, TrustLevel.projectVerified);
			expect(first.trustLevel.requiresWarning, isFalse);
			expect(first.status.isUsable, isFalse);
			expect(first.fingerprint, 'nl-1');
			expect(first.notes, contains('Audited 2026-01'));

			// Every entry, however it spelled the country, is normalised.
			expect(byId['de-1']!.countryCode, 'DE');
		});

		test('skips an entry with an unusable protocol and keeps the rest', () async {
			final body = manifestJson([
				serverEntry(id: 'ok-1', hostname: 'vpn1.example.org', country: 'nl'),
				serverEntry(
					id: 'bad-protocol',
					hostname: 'vpn3.example.org',
					country: 'fr',
					protocol: 'carrier-pigeon',
				),
			]);

			final outcome = await providerFor(body).refresh();

			expect(outcome.isOk, isTrue);
			expect(outcome.servers, hasLength(1));
			expect(outcome.servers.single.id, 'ok-1');
		});

		test('skips an entry with a non two-letter country and keeps the rest', () async {
			final body = manifestJson([
				serverEntry(id: 'ok-1', hostname: 'vpn1.example.org', country: 'nl'),
				serverEntry(
					id: 'bad-country',
					hostname: 'vpn4.example.org',
					country: 'JAPAN',
				),
			]);

			final outcome = await providerFor(body).refresh();

			expect(outcome.isOk, isTrue);
			expect(outcome.servers, hasLength(1));
			expect(outcome.servers.single.id, 'ok-1');
		});

		test('skips an entry whose configuration fails validation', () async {
			final body = manifestJson([
				serverEntry(id: 'ok-1', hostname: 'vpn1.example.org', country: 'nl'),
				serverEntry(
					id: 'unsafe-config',
					hostname: 'vpn5.example.org',
					country: 'se',
					config: kWireGuardWithPostUp,
				),
			]);

			final outcome = await providerFor(body).refresh();

			expect(outcome.isOk, isTrue);
			expect(outcome.servers, hasLength(1));
			expect(outcome.servers.single.id, 'ok-1');
		});

		test('serves a validated configuration for an accepted server only', () async {
			final body = manifestJson([
				serverEntry(id: 'nl-1', hostname: 'vpn1.example.org', country: 'nl'),
				serverEntry(
					id: 'unsafe-config',
					hostname: 'vpn5.example.org',
					country: 'se',
					config: kWireGuardWithPostUp,
				),
			]);

			final provider = providerFor(body);
			await provider.refresh();

			final config = await provider.fetchConfig('nl-1');
			expect(config, isNotNull);
			expect(config!.providerId, 'manifest');
			expect(config.rawText, kWireGuardConfig.trim());
			expect(config.validated.kind, ProtocolKind.wireGuard);

			expect(await provider.fetchConfig('unsafe-config'), isNull);
			expect(await provider.fetchConfig('not-in-the-list'), isNull);
		});

		test('refuses a plain http manifest endpoint', () async {
			final fetcher = _FakeFetcher({
				'http://servers.phantrix.example/manifest.json': manifestJson([
					serverEntry(id: 'nl-1', hostname: 'vpn1.example.org', country: 'nl'),
				]),
			});
			final provider = ManifestProvider(
				fetcher: fetcher,
				manifestUrl: 'http://servers.phantrix.example/manifest.json',
			);

			final outcome = await provider.refresh();

			expect(outcome.isOk, isFalse);
			expect(outcome.servers, isEmpty);
			expect(outcome.error?.code, 'manifest.insecure_url');
			// Nothing was fetched: the scheme is rejected before any request.
			expect(fetcher.requested, isEmpty);
		});

		test('refuses an endpoint that was never configured', () async {
			final provider = ManifestProvider(
				fetcher: _FakeFetcher(),
				manifestUrl: '   ',
			);

			final outcome = await provider.refresh();

			expect(outcome.isOk, isFalse);
			expect(outcome.error?.code, 'manifest.not_configured');
		});

		test('refuses a body that is not JSON', () async {
			final outcome = await providerFor('this is not json').refresh();
			expect(outcome.isOk, isFalse);
			expect(outcome.error?.code, 'manifest.invalid_json');
		});

		test('refuses a body that is not an object', () async {
			final outcome = await providerFor('[1, 2, 3]').refresh();
			expect(outcome.isOk, isFalse);
			expect(outcome.error?.code, 'manifest.shape');
		});

		test('refuses a manifest with no supported version', () async {
			final outcome = await providerFor('{"version": 99, "servers": []}').refresh();
			expect(outcome.isOk, isFalse);
			expect(outcome.error?.code, 'manifest.version');
		});

		test('refuses a manifest with no server list', () async {
			final outcome = await providerFor('{"version": 1}').refresh();
			expect(outcome.isOk, isFalse);
			expect(outcome.error?.code, 'manifest.servers');
		});

		test('turns a transport failure into a failed refresh', () async {
			final provider = ManifestProvider(
				fetcher: _FakeFetcher(),
				manifestUrl: kManifestUrl,
			);

			final outcome = await provider.refresh();

			expect(outcome.isOk, isFalse);
			expect(outcome.error?.code, 'test.no_fixture');
			expect(outcome.servers, isEmpty);
		});

		test('turns an oversized body into a failed refresh', () async {
			final provider = ManifestProvider(
				fetcher: const _TooLargeFetcher(),
				manifestUrl: kManifestUrl,
			);

			final outcome = await provider.refresh();

			expect(outcome.isOk, isFalse);
			expect(outcome.error?.code, 'http.body_too_large');
		});
	});

	group('ManifestProvider trust', () {
		test('marks every server unverified when no signature is configured',
				() async {
			final body = manifestJson([
				serverEntry(id: 'nl-1', hostname: 'vpn1.example.org', country: 'nl'),
				serverEntry(id: 'de-1', hostname: 'vpn2.example.org', country: 'de'),
			]);

			final outcome = await providerFor(body).refresh();

			expect(outcome.servers, isNotEmpty);
			for (final server in outcome.servers) {
				expect(
					server.notes.any(
						(n) => n.contains('signature') && n.contains('unverified'),
					),
					isTrue,
					reason: '${server.id} must be described as unverified',
				);
			}
		});

		test('does not ask for a signature when none is configured', () async {
			final body = manifestJson([
				serverEntry(id: 'nl-1', hostname: 'vpn1.example.org', country: 'nl'),
			]);

			final fetcher = _FakeFetcher({kManifestUrl: body});
			final provider = ManifestProvider(
				fetcher: fetcher,
				manifestUrl: kManifestUrl,
			);

			await provider.refresh();

			expect(fetcher.requested, [Uri.parse(kManifestUrl)]);
		});

		test('honours the trust level each entry declares', () async {
			final body = manifestJson([
				serverEntry(id: 'a', hostname: 'a.example.org', country: 'nl',
						trust: 'project'),
				serverEntry(id: 'b', hostname: 'b.example.org', country: 'de',
						trust: 'community'),
				serverEntry(id: 'c', hostname: 'c.example.org', country: 'fr'),
			]);

			final outcome = await providerFor(body).refresh();
			final byId = {for (final s in outcome.servers) s.id: s.trustLevel};

			expect(byId['a'], TrustLevel.projectVerified);
			expect(byId['b'], TrustLevel.community);
			expect(byId['c'], TrustLevel.unknown);
		});

		test('drops the unverified note once a signature verifies', () async {
			final algorithm = Ed25519();
			final keyPair = await algorithm.newKeyPairFromSeed(
				List<int>.filled(32, 7),
			);
			final publicKey = await keyPair.extractPublicKey();
			final body = manifestJson([
				serverEntry(
					id: 'nl-1',
					hostname: 'vpn1.example.org',
					country: 'nl',
					trust: 'project',
				),
			]);
			final signature = await algorithm.sign(utf8.encode(body), keyPair: keyPair);

			const signatureUrl = 'https://servers.phantrix.example/manifest.sig';
			final fetcher = _FakeFetcher({
				kManifestUrl: body,
				signatureUrl: base64Url.encode(signature.bytes),
			});
			final provider = ManifestProvider(
				fetcher: fetcher,
				manifestUrl: kManifestUrl,
				signatureUrl: signatureUrl,
				trustedSigningKey: base64Url.encode(publicKey.bytes),
			);

			final outcome = await provider.refresh();

			expect(outcome.isOk, isTrue);
			expect(outcome.servers, hasLength(1));
			expect(
				outcome.servers.single.notes.any((n) => n.contains('unverified')),
				isFalse,
			);
			expect(outcome.servers.single.trustLevel, TrustLevel.projectVerified);
			expect(fetcher.requested, contains(Uri.parse(signatureUrl)));
		});

		test('keeps the unverified note when the signature does not match',
				() async {
			final algorithm = Ed25519();
			final keyPair = await algorithm.newKeyPairFromSeed(List<int>.filled(32, 7));
			final publicKey = await keyPair.extractPublicKey();
			final body = manifestJson([
				serverEntry(id: 'nl-1', hostname: 'vpn1.example.org', country: 'nl'),
			]);
			// A valid signature, but signed over a different document.
			final tamperedBody = manifestJson([
				serverEntry(id: 'nl-1', hostname: 'attacker.example.org', country: 'nl'),
			]);
			final signature = await algorithm.sign(
				utf8.encode(tamperedBody),
				keyPair: keyPair,
			);

			const signatureUrl = 'https://servers.phantrix.example/manifest.sig';
			final provider = ManifestProvider(
				fetcher: _FakeFetcher({
					kManifestUrl: body,
					signatureUrl: base64Url.encode(signature.bytes),
				}),
				manifestUrl: kManifestUrl,
				signatureUrl: signatureUrl,
				trustedSigningKey: base64Url.encode(publicKey.bytes),
			);

			final outcome = await provider.refresh();

			expect(outcome.isOk, isTrue);
			expect(outcome.servers, hasLength(1));
			expect(
				outcome.servers.single.notes.any((n) => n.contains('unverified')),
				isTrue,
			);
		});

		test('keeps the unverified note when only one of the pair is configured',
				() async {
			final body = manifestJson([
				serverEntry(id: 'nl-1', hostname: 'vpn1.example.org', country: 'nl'),
			]);
			const signatureUrl = 'https://servers.phantrix.example/manifest.sig';

			// A signature URL with no trusted key.
			final noKey = ManifestProvider(
				fetcher: _FakeFetcher({kManifestUrl: body, signatureUrl: ''}),
				manifestUrl: kManifestUrl,
				signatureUrl: signatureUrl,
			);
			expect(
				(await noKey.refresh()).servers.single.notes
						.any((n) => n.contains('unverified')),
				isTrue,
			);

			// A trusted key with no signature URL.
			final noUrl = ManifestProvider(
				fetcher: _FakeFetcher({kManifestUrl: body}),
				manifestUrl: kManifestUrl,
				trustedSigningKey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
			);
			expect(
				(await noUrl.refresh()).servers.single.notes
						.any((n) => n.contains('unverified')),
				isTrue,
			);
		});
	});

	group('ManifestProvider metadata', () {
		test('describes itself as the project list', () {
			final provider = ManifestProvider(
				fetcher: _FakeFetcher(),
				manifestUrl: kManifestUrl,
			);

			expect(provider.id, 'manifest');
			expect(provider.label, 'Project server list');
			expect(provider.autoRefresh, isTrue);
			expect(provider.capabilities.servesConfigurations, isTrue);
			expect(provider.capabilities.protocols, {
				ProtocolKind.wireGuard,
				ProtocolKind.openVpn,
			});
			expect(provider.trustDescription, contains('project'));
		});
	});
}

/// A transport that reports the body as too large.
class _TooLargeFetcher implements HttpFetcher {
	const _TooLargeFetcher();

	@override
	Future<String> get(Uri url) async =>
			throw const BodyTooLargeException(4096, 1024);

	@override
	int get maxBodyBytes => 1024;
}
