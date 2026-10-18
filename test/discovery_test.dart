import 'package:http/http.dart' as http;

import 'package:flutter_test/flutter_test.dart';

import 'package:phantrix_core/phantrix_core.dart';

import 'package:phantrix/discovery/discovery_controller.dart';
import 'package:phantrix/net/app_http_fetcher.dart';
import 'package:phantrix/ui/screens/country_directory.dart';

/// Builds a server with only the fields a test cares about.
VpnServer server({
  required String id,
  required String country,
  int? latencyMs,
  TrustLevel trust = TrustLevel.projectVerified,
  ProtocolKind protocol = ProtocolKind.openVpn,
  ServerStatus status = ServerStatus.online,
  double? latitude,
  double? longitude,
  String? hostname,
}) => VpnServer(
  id: id,
  hostname: hostname ?? '$id.example',
  hostAddress: '192.0.2.1',
  port: 51820,
  protocol: protocol,
  trustLevel: trust,
  countryCode: country,
  providerId: 'test',
  status: status,
  latitude: latitude,
  longitude: longitude,
  metrics: ServerMetrics(latencyMs: latencyMs),
);

/// Builds a snapshot the same way [ServerDirectory.snapshot] does.
///
/// The grouping is done with [putIfAbsent] on purpose: a map literal keyed by
/// country would silently keep only the last server of each country, which
/// would make every per-country assertion wrong in a way that looks like a
/// production bug.
DirectorySnapshot snapshotOf(List<VpnServer> servers, {DirectoryState? state}) {
  final byCountry = <String, List<VpnServer>>{};
  for (final server in servers) {
    byCountry.putIfAbsent(server.countryCode, () => <VpnServer>[]).add(server);
  }
  return DirectorySnapshot(
    servers: servers,
    state: state ?? DirectoryState.fresh,
    byCountry: byCountry,
    lastFetchedAt: DateTime(2026, 1, 1),
    providerErrors: const {},
  );
}

/// A provider whose result the test dictates.
class _FakeProvider implements ServerProvider {
  _FakeProvider({
    required this.id,
    this.servers = const [],
    this.error,
    this.throws = false,
  });

  @override
  final String id;

  List<VpnServer> servers;
  AppError? error;
  bool throws;
  int calls = 0;

  @override
  String get label => id;

  @override
  ProviderCapabilities get capabilities => const ProviderCapabilities();

  @override
  bool get autoRefresh => true;

  @override
  String get trustDescription => 'test';

  @override
  HttpFetcher get fetcher => throw UnimplementedError('not used');

  @override
  Future<RefreshOutcome> refresh({bool force = false}) async {
    calls++;
    if (throws) {
      throw StateError('boom');
    }
    if (error != null) {
      return RefreshOutcome.failure(error!);
    }
    // A live fetch reports the moment it ran, which is what makes the
    // directory "fresh". A fixed absolute date here used to look recent
    // when the test was written; it silently aged out into DirectoryState.stale
    // and broke the freshness assertion months later, so it is "now".
    return RefreshOutcome(
      servers: servers,
      usedCache: false,
      fetchedAt: DateTime.now(),
    );
  }

  @override
  Future<ProviderConfig?> fetchConfig(String serverId) async => null;
}

// A client that is never used: these tests never open a socket.
http.Client _throwawayClient() => http.Client();

void main() {
  group('buildCountryEntries', () {
    test('is empty for an empty directory', () {
      expect(buildCountryEntries(DirectorySnapshot.empty), isEmpty);
    });

    test('groups servers by country', () {
      final entries = buildCountryEntries(
        snapshotOf([
          server(id: 'a', country: 'DE'),
          server(id: 'b', country: 'DE'),
          server(id: 'c', country: 'JP'),
        ]),
      );
      expect(entries, hasLength(2));
      expect(entries.firstWhere((e) => e.code == 'DE').serverCount, 2);
    });

    test('normalises the country code to upper case', () {
      final entries = buildCountryEntries(
        snapshotOf([server(id: 'a', country: 'de')]),
      );
      expect(entries.single.code, 'DE');
    });

    test('reports the best *measured* latency only', () {
      final entries = buildCountryEntries(
        snapshotOf([
          server(id: 'a', country: 'DE', latencyMs: 90),
          server(id: 'b', country: 'DE', latencyMs: 30),
          server(id: 'c', country: 'DE'),
        ]),
      );
      expect(entries.single.bestLatencyMs, 30);
    });

    test('an unmeasured country has a null latency, never a zero', () {
      final entries = buildCountryEntries(
        snapshotOf([server(id: 'a', country: 'DE')]),
      );
      expect(entries.single.bestLatencyMs, isNull);
    });

    test('a measured zero latency is preserved and still sorts first', () {
      final entries = sortCountryEntries(
        buildCountryEntries(
          snapshotOf([
            server(id: 'a', country: 'AA', latencyMs: 120),
            server(id: 'b', country: 'BB', latencyMs: 0),
          ]),
        ),
        'latency',
      );
      expect(entries.first.code, 'BB');
      expect(entries.first.bestLatencyMs, 0);
    });

    test('counts only usable servers as usable', () {
      final entries = buildCountryEntries(
        snapshotOf([
          server(id: 'a', country: 'DE'),
          server(id: 'b', country: 'DE', status: ServerStatus.online),
          server(id: 'c', country: 'DE', status: ServerStatus.offline),
        ]),
      );
      expect(entries.single.serverCount, 3);
      expect(entries.single.usableCount, 2);
    });

    test('the weakest trust level wins, so a public relay is never hidden', () {
      final entries = buildCountryEntries(
        snapshotOf([
          server(id: 'a', country: 'DE', trust: TrustLevel.projectVerified),
          server(id: 'b', country: 'DE', trust: TrustLevel.publicRelay),
          server(id: 'c', country: 'DE', trust: TrustLevel.community),
        ]),
      );
      expect(entries.single.trust, TrustLevel.publicRelay);
    });

    test('collects the protocols actually offered', () {
      final entries = buildCountryEntries(
        snapshotOf([
          server(id: 'a', country: 'DE', protocol: ProtocolKind.wireGuard),
          server(id: 'b', country: 'DE', protocol: ProtocolKind.openVpn),
        ]),
      );
      expect(entries.single.protocols, {
        ProtocolKind.wireGuard,
        ProtocolKind.openVpn,
      });
    });
  });

  group('sortCountryEntries', () {
    List<CountryEntry> sample() => buildCountryEntries(
      snapshotOf([
        server(id: 'a', country: 'DE', latencyMs: 50),
        server(id: 'b', country: 'JP', latencyMs: 10),
        server(id: 'c', country: 'BR', latencyMs: 300),
      ]),
    );

    test('by latency is ascending', () {
      expect(sortCountryEntries(sample(), 'latency').map((e) => e.code), [
        'JP',
        'DE',
        'BR',
      ]);
    });

    test('by name is alphabetical', () {
      expect(sortCountryEntries(sample(), 'name').map((e) => e.code), [
        'BR',
        'DE',
        'JP',
      ]);
    });

    test('by count is descending', () {
      final entries = buildCountryEntries(
        snapshotOf([
          server(id: 'a', country: 'DE', latencyMs: 50),
          server(id: 'b', country: 'JP', latencyMs: 10),
          server(id: 'c', country: 'BR', latencyMs: 300),
          server(id: 'd', country: 'BR', latencyMs: 310),
        ]),
      );
      expect(sortCountryEntries(entries, 'count').map((e) => e.code), [
        'BR',
        'DE',
        'JP',
      ]);
    });

    test('countries with no measurement sort last, not first', () {
      final entries = sortCountryEntries(
        buildCountryEntries(
          snapshotOf([
            server(id: 'a', country: 'DE', latencyMs: 50),
            server(id: 'b', country: 'ZZ'),
          ]),
        ),
        'latency',
      );
      expect(entries.first.code, 'DE');
      expect(entries.last.code, 'ZZ');
    });

    test('an unknown sort mode falls back rather than throwing', () {
      expect(sortCountryEntries(sample(), 'nonsense'), hasLength(3));
    });

    test('sorting does not mutate its input', () {
      final entries = sample();
      final before = entries.map((e) => e.code).toList();
      sortCountryEntries(entries, 'name');
      expect(entries.map((e) => e.code), before);
    });
  });

  group('mapServersOf', () {
    test('drops servers with no coordinates rather than pinning (0,0)', () {
      final pins = mapServersOf([
        server(id: 'a', country: 'DE', latitude: 52.5, longitude: 13.4),
        server(id: 'b', country: 'JP'),
      ]);
      expect(pins, hasLength(1));
      expect(pins.single.latitude, 52.5);
    });

    test('is empty for an empty list', () {
      expect(mapServersOf(const []), isEmpty);
    });
  });

  group('DiscoveryController', () {
    test('connect readiness refreshes provider data even when disk cache is populated', () async {
      final cachedServer = server(id: 'cached', country: 'HK');
      final freshServer = server(id: 'fresh', country: 'HK');
      final cache = MemoryDirectoryCache();
      cache.write([cachedServer], DateTime.now());
      final provider = _FakeProvider(id: 'a', servers: [freshServer]);
      final controller = DiscoveryController(
        providers: [provider],
        cache: cache,
      );
      addTearDown(controller.dispose);

      controller.restoreFromCache();
      expect(controller.snapshot.servers.single.id, 'cached');
      expect(controller.hasLiveDirectoryData, isFalse);

      final snapshot = await controller.ensureLoaded();

      expect(provider.calls, 1);
      expect(controller.hasLiveDirectoryData, isTrue);
      expect(snapshot.servers.single.id, 'fresh');
    });

    test(
      'cached data remains available when the live provider fails',
      () async {
        final cachedServer = server(id: 'cached', country: 'HK');
        final cache = MemoryDirectoryCache();
        cache.write([cachedServer], DateTime.now());
        final provider = _FakeProvider(
          id: 'a',
          error: const AppError(
            group: ErrorGroup.network,
            code: 'test.offline',
            message: 'Offline',
          ),
        );
        final controller = DiscoveryController(
          providers: [provider],
          cache: cache,
        );
        addTearDown(controller.dispose);
        controller.restoreFromCache();

        final snapshot = await controller.ensureLoaded();

        expect(provider.calls, 1);
        expect(controller.hasLiveDirectoryData, isFalse);
        expect(snapshot.servers.single.id, 'cached');
        expect(snapshot.providerErrors.containsKey('a'), isTrue);
      },
    );

    test('publishes the servers a provider returned', () async {
      final controller = DiscoveryController(
        providers: [
          _FakeProvider(
            id: 'a',
            servers: [server(id: 's1', country: 'DE')],
          ),
        ],
      );
      addTearDown(controller.dispose);

      final snapshot = await controller.refresh();
      expect(snapshot.serverCount, 1);
      expect(snapshot.countFor('DE'), 1);
      expect(snapshot.state, DirectoryState.fresh);
    });

    test('records a provider failure and still shows what it can', () async {
      final controller = DiscoveryController(
        providers: [
          _FakeProvider(
            id: 'good',
            servers: [server(id: 's1', country: 'DE')],
          ),
          _FakeProvider(
            id: 'bad',
            error: const AppError(
              group: ErrorGroup.provider,
              code: 'provider.down',
              message: 'Source unavailable.',
            ),
          ),
        ],
      );
      addTearDown(controller.dispose);

      final snapshot = await controller.refresh();
      expect(snapshot.serverCount, 1);
      expect(snapshot.providerErrors.keys, contains('bad'));
      expect(snapshot.providerErrors, isNot(contains('good')));
    });

    test('a provider that throws is contained, not fatal', () async {
      final controller = DiscoveryController(
        providers: [
          _FakeProvider(id: 'boom', throws: true),
          _FakeProvider(
            id: 'good',
            servers: [server(id: 's1', country: 'DE')],
          ),
        ],
      );
      addTearDown(controller.dispose);

      final snapshot = await controller.refresh();
      expect(snapshot.serverCount, 1);
      expect(snapshot.providerErrors.keys, contains('boom'));
    });

    test(
      'every provider failing leaves the directory empty and explains why',
      () async {
        final controller = DiscoveryController(
          providers: [
            _FakeProvider(
              id: 'bad',
              error: const AppError(
                group: ErrorGroup.provider,
                code: 'provider.down',
                message: 'Source unavailable.',
              ),
            ),
          ],
        );
        addTearDown(controller.dispose);

        final snapshot = await controller.refresh();
        expect(snapshot.isEmpty, isTrue);
        expect(snapshot.state, DirectoryState.empty);
        expect(snapshot.providerErrors, hasLength(1));
      },
    );

    test(
      'an empty result does not wipe servers from an earlier refresh',
      () async {
        final provider = _FakeProvider(
          id: 'a',
          servers: [server(id: 's1', country: 'DE')],
        );
        final controller = DiscoveryController(providers: [provider]);
        addTearDown(controller.dispose);

        await controller.refresh();
        provider.servers = const [];

        final snapshot = await controller.refresh();
        expect(
          snapshot.serverCount,
          1,
          reason: 'a dead feed must not empty the list',
        );
      },
    );

    test(
      'two providers offering the same endpoint are de-duplicated',
      () async {
        final shared = server(
          id: 'same',
          country: 'DE',
          hostname: 'shared.example',
        );
        final controller = DiscoveryController(
          providers: [
            _FakeProvider(id: 'a', servers: [shared]),
            _FakeProvider(id: 'b', servers: [shared]),
          ],
        );
        addTearDown(controller.dispose);

        final snapshot = await controller.refresh();
        expect(snapshot.serverCount, 1);
      },
    );

    test('a refresh is not run twice concurrently', () async {
      final provider = _FakeProvider(
        id: 'a',
        servers: [server(id: 's1', country: 'DE')],
      );
      final controller = DiscoveryController(providers: [provider]);
      addTearDown(controller.dispose);

      await Future.wait([controller.refresh(), controller.refresh()]);
      expect(provider.calls, 1);
    });

    test('refresh publishes on the stream', () async {
      final controller = DiscoveryController(
        providers: [
          _FakeProvider(
            id: 'a',
            servers: [server(id: 's1', country: 'DE')],
          ),
        ],
      );
      addTearDown(controller.dispose);

      final published = <DirectorySnapshot>[];
      final sub = controller.snapshots.listen(published.add);
      addTearDown(sub.cancel);

      await controller.refresh();
      await Future<void>.delayed(Duration.zero);

      expect(published, isNotEmpty);
      expect(published.last.serverCount, 1);
    });

    test('an empty provider list reports empty rather than throwing', () async {
      final controller = DiscoveryController(providers: const []);
      addTearDown(controller.dispose);

      final snapshot = await controller.refresh();
      expect(snapshot.isEmpty, isTrue);
      expect(snapshot.state, DirectoryState.empty);
    });
  });

  group('buildProviders', () {
    test('maps the VPN Gate id to a real provider', () {
      final providers = buildProviders(
        enabled: const {ProviderId.vpnGate},
        fetcher: AppHttpFetcher(client: _throwawayClient()),
      );
      addTearDown(
        providers.first.fetcher is AppHttpFetcher
            ? (providers.first.fetcher as AppHttpFetcher).close
            : () {},
      );
      expect(providers.single.id, 'vpngate');
      expect(providers.single.trustDescription, isNotEmpty);
    });

    test('nothing enabled produces no providers', () {
      expect(
        buildProviders(
          enabled: const {},
          fetcher: AppHttpFetcher(client: _throwawayClient()),
        ),
        isEmpty,
      );
    });
  });

  group('ProviderId', () {
    test('round-trips its wire name', () {
      for (final id in ProviderId.values) {
        expect(ProviderId.fromWire(id.wireName), id);
      }
    });

    test('an unknown wire name returns null rather than guessing', () {
      expect(ProviderId.fromWire('nope'), isNull);
    });
  });
}
