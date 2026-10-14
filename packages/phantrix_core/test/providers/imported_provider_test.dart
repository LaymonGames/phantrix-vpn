import 'package:phantrix_core/src/model/trust_level.dart';
import 'package:phantrix_core/src/protocol/protocol_kind.dart';
import 'package:phantrix_core/src/providers/common/http_fetcher.dart';
import 'package:phantrix_core/src/providers/imported/imported_provider.dart';
import 'package:test/test.dart';

const String kPrivateKey = '02R31BtVMJe/5r8cMd8uRVf6DysDrWKFXxDlMdRDU6c=';
const String kPeerKey = 'iGaPncC709q7zIxUD9OMJENN3dh+W40oQx0Lv7AStp8=';

/// A full-tunnel WireGuard profile that parses and passes every policy check.
const String kWireGuard = '''
[Interface]
PrivateKey = $kPrivateKey
Address = 10.7.0.2/32
DNS = 10.7.0.1
MTU = 1280

[Peer]
PublicKey = $kPeerKey
AllowedIPs = 0.0.0.0/0
Endpoint = vpn.example.net:51820
PersistentKeepalive = 25
''';

/// Same profile, but it asks `wg-quick` to run a shell command. Phantrix never
/// executes directives from a configuration file, so this must be refused.
const String kWireGuardWithPostUp = '''
[Interface]
PrivateKey = $kPrivateKey
Address = 10.7.0.2/32
PostUp = rm -rf /

[Peer]
PublicKey = $kPeerKey
AllowedIPs = 0.0.0.0/0
Endpoint = vpn.example.net:51820
''';

/// A split-tunnel profile: usable, but the default route has to be added.
const String kWireGuardSplitTunnel = '''
[Interface]
PrivateKey = $kPrivateKey
Address = 10.7.0.2/32

[Peer]
PublicKey = $kPeerKey
AllowedIPs = 10.7.0.0/24
Endpoint = vpn.example.net:51820
''';

const String kCa = '''
-----BEGIN CERTIFICATE-----
MIIFazCCA1OgAwIBAgIRAIIQz7DSQONZRGPgu2OCiwAwDQYJKoZIhvcNAQELBQAw
TzELMAkGA1UEBhMCVVMxKTAnBgNVBAoTIEludGVybmV0IFNlY3VyaXR5IFJlc2Vh
-----END CERTIFICATE-----
''';

/// An OpenVPN profile with an inline CA and a single remote, which is the
/// minimum the validator needs to authenticate the server.
const String kOpenVpn = '''
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

/// Same profile, but it asks OpenVPN to run a program at start-up.
const String kOpenVpnWithUp = '''
client
dev tun
proto udp
remote vpn.example.net 1194
cipher AES-256-GCM
up /bin/sh -c "id"

<ca>
$kCa
</ca>
''';

/// A transport that is never used by [ImportedProvider]: imports never touch
/// the network. It fails loudly if something regresses and starts fetching.
class _NeverCalledFetcher implements HttpFetcher {
	const _NeverCalledFetcher();

	@override
	Future<String> get(Uri url) async =>
			throw StateError('ImportedProvider must not use the network');

	@override
	int get maxBodyBytes => 1024 * 1024;
}

ImportedProvider newProvider({void Function(List<ImportedConfig>)? onChanged}) =>
		ImportedProvider(fetcher: const _NeverCalledFetcher(), onChanged: onChanged);

void main() {
	group('ImportedProvider.import', () {
		test('accepts a WireGuard configuration', () async {
			final provider = newProvider();

			final result = await provider.import(kWireGuard, name: 'Home');

			expect(result.isOk, isTrue, reason: '${result.errorOrNull?.message}');
			final entry = result.valueOr;
			expect(entry.protocol, ProtocolKind.wireGuard);
			expect(entry.label, 'Home');
			expect(entry.endpointLabel, 'vpn.example.net');
			expect(entry.rawText, kWireGuard.trim());
			expect(provider.imports, hasLength(1));

			final config = await provider.fetchConfig(entry.id);
			expect(config, isNotNull);
			expect(config!.providerId, 'imported');
			expect(config.rawText, kWireGuard.trim());
			expect(config.validated.kind, ProtocolKind.wireGuard);
			expect(config.requiresCredentials, isFalse);
			expect(
				config.validated.wireGuard!.peers.single.carriesDefaultRoute,
				isTrue,
			);
		});

		test('defaults the label to the endpoint host', () async {
			final provider = newProvider();
			final entry = (await provider.import(kWireGuard)).valueOr;
			expect(entry.label, 'vpn.example.net');
			expect(entry.endpointLabel, 'vpn.example.net');
		});

		test('adds the default route to a split-tunnel configuration', () async {
			final provider = newProvider();
			final entry = (await provider.import(kWireGuardSplitTunnel)).valueOr;

			expect(entry.warnings, isNotEmpty);
			expect(entry.rawText, kWireGuardSplitTunnel.trim());
			expect(
				provider.imports.single.configuration.wireGuard!.peers.single
						.carriesDefaultRoute,
				isTrue,
				reason: 'the stored configuration must be the repaired one',
			);
		});

		test('rejects a WireGuard configuration that runs commands', () async {
			final provider = newProvider();

			final result = await provider.import(kWireGuardWithPostUp);

			expect(result.isOk, isFalse);
			expect(result.errorOrNull?.code, 'wg.forbidden_directive');
			expect(provider.imports, isEmpty);
		});

		test('accepts an OpenVPN configuration with an inline CA', () async {
			final provider = newProvider();

			final result = await provider.import(kOpenVpn, name: 'Office');

			expect(result.isOk, isTrue, reason: '${result.errorOrNull?.message}');
			final entry = result.valueOr;
			expect(entry.protocol, ProtocolKind.openVpn);
			expect(entry.label, 'Office');
			expect(entry.endpointLabel, 'vpn.example.net');

			final config = await provider.fetchConfig(entry.id);
			expect(config, isNotNull);
			expect(config!.validated.kind, ProtocolKind.openVpn);
			expect(config.validated.openVpn!.remotes.single.host, 'vpn.example.net');
			expect(config.validated.openVpn!.inlineBlocks.containsKey('ca'), isTrue);
			expect(config.requiresCredentials, isFalse);
		});

		test('rejects an OpenVPN configuration that runs a program', () async {
			final provider = newProvider();

			final result = await provider.import(kOpenVpnWithUp);

			expect(result.isOk, isFalse);
			expect(result.errorOrNull?.code, 'ovpn.forbidden_directive');
			expect(result.errorOrNull?.detail?['directive'], 'up');
			expect(provider.imports, isEmpty);
		});

		test('rejects empty text and unrecognisable text', () async {
			final provider = newProvider();

			final empty = await provider.import('   ');
			expect(empty.isOk, isFalse);
			expect(empty.errorOrNull?.code, 'import.empty');

			final garbage = await provider.import('just some text, nothing like a VPN');
			expect(garbage.isOk, isFalse);
			expect(garbage.errorOrNull?.code, 'import.unknown_protocol');

			expect(provider.imports, isEmpty);
		});

		test('notifies the listener on every change', () async {
			var notifications = 0;
			final provider = newProvider(onChanged: (_) => notifications++);

			final entry = (await provider.import(kWireGuard)).valueOr;
			expect(notifications, 1);

			provider.rename(entry.id, 'Renamed');
			expect(notifications, 2);

			provider.remove(entry.id);
			expect(notifications, 3);
		});
	});

	group('ImportedProvider.detectProtocol', () {
		test('recognises a WireGuard configuration', () {
			expect(ImportedProvider.detectProtocol(kWireGuard), ProtocolKind.wireGuard);
		});

		test('recognises a WireGuard configuration that only has a peer', () {
			const text = '''
# a comment
[Peer]
PublicKey = $kPeerKey
''';
			expect(ImportedProvider.detectProtocol(text), ProtocolKind.wireGuard);
		});

		test('recognises an OpenVPN configuration', () {
			expect(ImportedProvider.detectProtocol(kOpenVpn), ProtocolKind.openVpn);
		});

		test('recognises a bare OpenVPN directive list', () {
			const text = 'dev tun\nproto udp\nremote 1.2.3.4\n';
			expect(ImportedProvider.detectProtocol(text), ProtocolKind.openVpn);
		});

		test('returns null for text that is not a configuration', () {
			expect(ImportedProvider.detectProtocol('hello world'), isNull);
			expect(ImportedProvider.detectProtocol(''), isNull);
			expect(ImportedProvider.detectProtocol('   \n  '), isNull);
		});
	});

	group('ImportedProvider.remove and rename', () {
		test('removes a stored configuration', () async {
			final provider = newProvider();
			final entry = (await provider.import(kWireGuard)).valueOr;
			expect(provider.imports, hasLength(1));

			provider.remove(entry.id);

			expect(provider.imports, isEmpty);
			expect(await provider.fetchConfig(entry.id), isNull);
			expect((await provider.refresh()).servers, isEmpty);
		});

		test('renames a stored configuration', () async {
			final provider = newProvider();
			final entry = (await provider.import(kWireGuard)).valueOr;

			provider.rename(entry.id, 'new name');

			final stored = provider.imports.single;
			expect(stored.id, entry.id);
			expect(stored.label, 'new name');
			// The stored text and the validated configuration survive the rename.
			expect(stored.rawText, kWireGuard.trim());
			expect((await provider.fetchConfig(entry.id))!.validated.kind,
					ProtocolKind.wireGuard);
		});

		test('rename only touches the requested id', () async {
			final provider = newProvider();
			final first = (await provider.import(kWireGuard)).valueOr;
			final second = (await provider.import(kOpenVpn)).valueOr;
			expect(first.id, isNot(second.id));

			provider.rename(first.id, 'renamed');

			final labels = {
				for (final entry in provider.imports) entry.id: entry.label,
			};
			expect(labels[first.id], 'renamed');
			expect(labels[second.id], 'vpn.example.net');
		});

		test('remove and rename tolerate an unknown id', () {
			final provider = newProvider();
			provider.remove('nope');
			provider.rename('nope', 'whatever');
			expect(provider.imports, isEmpty);
		});
	});

	group('ImportedProvider.refresh', () {
		test('exposes imports as untrusted, metadata-only servers', () async {
			final provider = newProvider();
			final entry = (await provider.import(kWireGuard, name: 'Home')).valueOr;

			final outcome = await provider.refresh();

			expect(outcome.isOk, isTrue);
			expect(outcome.usedCache, isTrue);
			expect(outcome.servers, hasLength(1));

			final server = outcome.servers.single;
			expect(server.id, entry.id);
			expect(server.hostname, 'Home');
			expect(server.hostAddress, 'vpn.example.net');
			expect(server.protocol, ProtocolKind.wireGuard);
			expect(server.trustLevel, TrustLevel.imported);
			expect(server.status.isUsable, isFalse);
		});

		test('describes itself as a provider that needs the user', () {
			final provider = newProvider();
			expect(provider.id, 'imported');
			expect(provider.autoRefresh, isFalse);
			expect(provider.capabilities.requiresUserAction, isTrue);
			expect(provider.capabilities.servesConfigurations, isTrue);
			expect(provider.capabilities.servesMetadataOnly, isFalse);
			expect(provider.capabilities.protocols, {
				ProtocolKind.wireGuard,
				ProtocolKind.openVpn,
			});
			expect(provider.trustDescription, contains('You supplied'));
		});
	});

	group('ImportedConfig.toServer', () {
		test('never claims the project verified the configuration', () async {
			final provider = newProvider();
			final entry = (await provider.import(kOpenVpn)).valueOr;

			final server = entry.toServer();

			expect(server.trustLevel, TrustLevel.imported);
			expect(
				server.notes.any((n) => n.contains('Not verified by the project')),
				isTrue,
			);
		});
	});
}
