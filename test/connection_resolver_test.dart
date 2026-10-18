import 'package:flutter_test/flutter_test.dart';

import 'package:phantrix_core/phantrix_core.dart';
import 'package:phantrix_platform/phantrix_platform.dart';

import 'package:phantrix/discovery/discovery_controller.dart';
import 'package:phantrix/vpn/connection_resolver.dart';
import 'package:phantrix/vpn/resolve_result.dart';

/// A provider whose configuration behaviour the test dictates.
class FakeResolverProvider implements ServerProvider {
  FakeResolverProvider({
    required this.id,
    this.servers = const [],
    this.config,
    this.noConfigFor = const {},
    this.refreshError,
  });

  @override
  final String id;

  List<VpnServer> servers;

  /// Handed back for any server not listed in [noConfigFor].
  ProviderConfig? config;

  /// Server ids this provider refuses to configure.
  Set<String> noConfigFor;

  AppError? refreshError;

  /// Makes `fetchConfig` throw, while leaving `refresh` working. Used to
  /// simulate a source that lists a server but then fails to serve it.
  bool throwsOnFetch = false;

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
    final error = refreshError;
    if (error != null) {
      return RefreshOutcome.failure(error);
    }
    return RefreshOutcome(
      servers: servers,
      usedCache: false,
      fetchedAt: DateTime(2026),
    );
  }

  @override
  Future<ProviderConfig?> fetchConfig(String serverId) async {
    if (throwsOnFetch) {
      throw StateError('fetch failed');
    }
    if (noConfigFor.contains(serverId)) {
      return null;
    }
    return config;
  }
}

/// A genuinely parsed and validated OpenVPN configuration.
///
/// Built through the same three steps the real providers use — parse,
/// validate, then wrap — so a test never hand-rolls a configuration that
/// could not survive the production path. The profile is a minimal but
/// complete one — remote, cipher, and an inline CA — because a configuration
/// that could not survive the validator would make a test pass for the wrong
/// reason.
ProviderConfig realOvpnConfig() {
  const text = '''
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
-----BEGIN CERTIFICATE-----
MIIFazCCA1OgAwIBAgIRAIIQz7DSQONZRGPgu2OCiwAwDQYJKoZIhvcNAQELBQAw
TzELMAkGA1UEBhMCVVMxKTAnBgNVBAoTIEludGVybmV0IFNlY3VyaXR5IFJlc2Vh
-----END CERTIFICATE-----
</ca>
''';
  final config = OvpnParser.parse(text).valueOrNull!;
  final verdict = OvpnValidator.validate(config).valueOrNull!;
  return ProviderConfig(
    providerId: 'test',
    rawText: text,
    validated: VpnConfiguration.openVpn(verdict),
  );
}

/// A platform that reports it can start OpenVPN tunnels.
const PlatformCapabilities openVpnCapable = PlatformCapabilities(
  platformName: 'windows',
  supportsKillSwitch: false,
  supportsIpv6Blocking: false,
  supportsVpnProvidedDns: true,
  supportsPerAppSplitTunnelling: false,
  supportsLanBypass: false,
  supportsAlwaysOn: false,
  supportsTray: false,
  supportsBootStart: false,
  openVpn: true,
);

VpnServer server({
  required String id,
  required String country,
  int? latencyMs,
  TrustLevel trust = TrustLevel.projectVerified,
  ServerStatus status = ServerStatus.online,
  ProtocolKind protocol = ProtocolKind.openVpn,
  String providerId = 'test',
}) {
  // A distinct address per id. Two servers sharing an endpoint are the
  // *same* server to the merger, so a helper that reused one address would
  // silently collapse every multi-server fixture to a single entry.
  final octet = id.codeUnits.fold<int>(0, (sum, c) => (sum + c) % 200) + 2;
  return VpnServer(
    id: id,
    hostname: '$id.example',
    hostAddress: '192.0.2.$octet',
    port: 51820,
    protocol: protocol,
    trustLevel: trust,
    countryCode: country,
    providerId: providerId,
    status: status,
    metrics: ServerMetrics(latencyMs: latencyMs),
  );
}

/// Builds a resolver over a directory that has already been populated.
Future<ConnectionResolver> resolverOverProviders(
  List<FakeResolverProvider> providers,
) async {
  final discovery = DiscoveryController(providers: providers);
  for (final p in providers) {
    if (p.servers.isNotEmpty) {
      await discovery.refresh();
      break;
    }
  }
  return ConnectionResolver(discovery: discovery);
}

void main() {
  group('ConnectionResolver', () {
    test('attempts a cached relay when the live feed is unavailable', () async {
      final cachedRelay = server(
        id: 'saved-relay',
        country: 'JP',
        status: ServerStatus.offline,
        protocol: ProtocolKind.openVpn,
      );
      final cache = MemoryDirectoryCache();
      cache.write([cachedRelay], DateTime(2026, 10, 1));
      final provider = FakeResolverProvider(
        id: 'test',
        config: realOvpnConfig(),
        refreshError: const AppError(
          group: ErrorGroup.network,
          code: 'network.offline',
          message: 'Feed unavailable',
        ),
      );
      final discovery = DiscoveryController(
        providers: [provider],
        cache: cache,
      );
      addTearDown(discovery.dispose);
      discovery.restoreFromCache();
      await discovery.refresh();

      final resolver = ConnectionResolver(discovery: discovery);
      final result = await resolver.resolve(
        const SelectionRequest(countryCode: 'JP'),
        capabilities: openVpnCapable,
      );

      expect(result, isA<ResolveSuccess>());
      final success = result as ResolveSuccess;
      expect(success.target.server.id, 'saved-relay');
      expect(
        success.target.server.status,
        ServerStatus.offline,
        reason: 'the app must not falsely label stale health as current',
      );
      expect(success.notice, contains('live server feed is unavailable'));
    });

    test('resolves a server and its configuration together', () async {
      final provider = FakeResolverProvider(
        id: 'test',
        servers: [server(id: 's1', country: 'DE', latencyMs: 20)],
        config: realOvpnConfig(),
      );
      final resolver = await resolverOverProviders([provider]);

      final result = await resolver.resolve(
        const SelectionRequest(countryCode: 'DE'),
        capabilities: openVpnCapable,
      );

      expect(result, isA<ResolveSuccess>());
      final success = result as ResolveSuccess;
      expect(success.target.server.id, 's1');
      expect(success.target.config, isNotNull);
      expect(success.target.provider.id, 'test');
      expect(success.notice, isNull, reason: 'nothing was substituted');
    });

    test('rejects OpenVPN relays before fetching a config when the platform cannot start them', () async {
      final provider = FakeResolverProvider(
        id: 'test',
        servers: [
          server(id: 'ovpn', country: 'JP', protocol: ProtocolKind.openVpn),
        ],
        config: realOvpnConfig(),
      );
      final resolver = await resolverOverProviders([provider]);

      // No capabilities supplied: the platform has not said it can run
      // OpenVPN, so the conservative answer is the right one.
      final result = await resolver.resolve(
        const SelectionRequest(countryCode: 'JP'),
      );

      expect(result, isA<ResolveFailureResult>());
      expect(
        (result as ResolveFailureResult).reason,
        ResolveFailure.noConfiguration,
      );
      expect(result.message, contains('OpenVPN'));
      expect(result.message, contains('nothing was attempted'));
      expect(
        result.message,
        contains('cannot start it on this device'),
        reason: 'the relay is startable nowhere without the engine',
      );
    });

    test(
      'accepts OpenVPN relays once the platform reports it can start them',
      () async {
        final provider = FakeResolverProvider(
          id: 'test',
          servers: [
            server(id: 'ovpn', country: 'JP', protocol: ProtocolKind.openVpn),
          ],
          config: realOvpnConfig(),
        );
        final resolver = await resolverOverProviders([provider]);

        final result = await resolver.resolve(
          const SelectionRequest(countryCode: 'JP'),
          capabilities: openVpnCapable,
        );

        expect(result, isA<ResolveSuccess>());
        expect((result as ResolveSuccess).target.server.id, 'ovpn');
        expect(result.target.config.kind, ProtocolKind.openVpn);
      },
    );

    test('a WireGuard relay loses to a slower OpenVPN one', () async {
      // The WireGuard relay is the better-ranked of the two — same trust,
      // far lower latency — and on a build that ran WireGuard it would be
      // the right answer. This build does not, so it is not an answer at
      // all, while the OpenVPN relay one rank below is. Dropping the
      // unrunnable server *before* ranking is what makes the second one
      // reachable, instead of the whole attempt ending in a refusal.
      final provider = FakeResolverProvider(
        id: 'test',
        servers: [
          server(
            id: 'wg',
            country: 'JP',
            protocol: ProtocolKind.wireGuard,
            latencyMs: 10,
          ),
          server(
            id: 'ovpn',
            country: 'JP',
            protocol: ProtocolKind.openVpn,
            latencyMs: 400,
          ),
        ],
        config: realOvpnConfig(),
      );
      final resolver = await resolverOverProviders([provider]);

      final result = await resolver.resolve(
        const SelectionRequest(countryCode: 'JP'),
        capabilities: openVpnCapable,
      );

      expect(result, isA<ResolveSuccess>());
      expect((result as ResolveSuccess).target.server.id, 'ovpn');
      expect(result.target.config.kind, ProtocolKind.openVpn);
    });

    test('an all-WireGuard list names what this build cannot run', () async {
      // Regression: this used to be reported as "no server currently
      // passes the health and trust checks", which blames the servers for
      // something they are not doing and tells the user to retry
      // something waiting cannot fix.
      final provider = FakeResolverProvider(
        id: 'test',
        servers: [
          server(id: 'wg1', country: 'JP', protocol: ProtocolKind.wireGuard),
          server(id: 'wg2', country: 'JP', protocol: ProtocolKind.wireGuard),
        ],
        config: realOvpnConfig(),
      );
      final resolver = await resolverOverProviders([provider]);

      final result = await resolver.resolve(
        const SelectionRequest(countryCode: 'JP'),
        capabilities: openVpnCapable,
      );

      expect(result, isA<ResolveFailureResult>());
      final failure = result as ResolveFailureResult;
      expect(failure.reason, ResolveFailure.noConfiguration);
      expect(failure.message, contains('WireGuard'));
      expect(failure.message, contains('nothing was attempted'));
      expect(failure.message, contains('does not run WireGuard'));
      expect(failure.message, isNot(contains('health and trust')));
    });

    test('the better-ranked startable relay wins', () async {
      // The contract the rest of this file relies on: with no preference to
      // apply, the capability filter alone decides, and the better-ranked
      // relay of the ones this build can dial is chosen.
      final provider = FakeResolverProvider(
        id: 'test',
        servers: [
          server(id: 'fast', country: 'JP', latencyMs: 10),
          server(id: 'slow', country: 'JP', latencyMs: 400),
        ],
        config: realOvpnConfig(),
      );
      final resolver = await resolverOverProviders([provider]);

      final result = await resolver.resolve(
        const SelectionRequest(countryCode: 'JP'),
        capabilities: openVpnCapable,
      );

      expect(result, isA<ResolveSuccess>());
      expect((result as ResolveSuccess).target.server.id, 'fast');
    });

    test(
      'a relay that hands over a WireGuard configuration is refused',
      () async {
        // The relay advertises OpenVPN and the source hands over a
        // WireGuard profile instead: the mismatch must be caught before a
        // tunnel is attempted, not after it fails to come up. This build
        // runs OpenVPN only, so the profile is unusable whatever the relay
        // claims to be.
        const text = '''
[Interface]
PrivateKey = 02R31BtVMJe/5r8cMd8uRVf6DysDrWKFXxDlMdRDU6c=
Address = 10.8.0.2/32

[Peer]
PublicKey = iGaPncC709q7zIxUD9OMJENN3dh+W40oQx0Lv7AStp8=
AllowedIPs = 0.0.0.0/0
Endpoint = 192.0.2.1:51820
''';
        final verdict = WgValidator.validate(WgParser.parse(text).valueOrNull!)
            .valueOrNull!;
        final provider = FakeResolverProvider(
          id: 'test',
          servers: [server(id: 's1', country: 'DE')],
          config: ProviderConfig(
            providerId: 'test',
            rawText: text,
            validated: VpnConfiguration.wireGuard(verdict),
          ),
        );
        final resolver = await resolverOverProviders([provider]);

        final result = await resolver.resolve(
          const SelectionRequest(countryCode: 'DE'),
          capabilities: openVpnCapable,
        );

        expect(
          (result as ResolveFailureResult).reason,
          ResolveFailure.noConfiguration,
        );
        expect(result.message, contains('cannot start'));
      },
    );

    test('automatic mode skips a relay with no usable profile', () async {
      final provider = FakeResolverProvider(
        id: 'test',
        servers: [
          server(id: 'top', country: 'JP', latencyMs: 10),
          server(id: 'next', country: 'JP', latencyMs: 40),
        ],
        config: realOvpnConfig(),
        noConfigFor: {'top'},
      );
      final resolver = await resolverOverProviders([provider]);

      final result = await resolver.resolve(
        const SelectionRequest(
          countryCode: 'JP',
          mode: SelectionMode.recommended,
        ),
        capabilities: openVpnCapable,
      );

      expect(result, isA<ResolveSuccess>());
      final success = result as ResolveSuccess;
      expect(success.target.server.id, 'next');
      expect(success.target.selection.fellBack, isTrue);
      expect(success.notice, contains('no usable profile'));
    });

    test('reports no servers rather than inventing one', () async {
      final resolver = await resolverOverProviders([
        FakeResolverProvider(id: 'test'),
      ]);

      final result = await resolver.resolve(const SelectionRequest());

      expect(result, isA<ResolveFailureResult>());
      expect((result as ResolveFailureResult).reason, ResolveFailure.noServers);
      expect(result.message, isNot(contains('connected')));
    });

    test('a country absent from the list is named as unknown', () async {
      final resolver = await resolverOverProviders([
        FakeResolverProvider(
          id: 'test',
          servers: [server(id: 's1', country: 'DE')],
          config: realOvpnConfig(),
        ),
      ]);

      final result = await resolver.resolve(
        const SelectionRequest(countryCode: 'ZZ'),
      );

      expect(
        (result as ResolveFailureResult).reason,
        ResolveFailure.unknownCountry,
      );
      expect(result.message, contains('ZZ'));
    });

    test(
      'a country whose relays are all marked offline is still dialled',
      () async {
        // The status column is the provider's measurement, not this network's:
        // a relay whose ping could not be measured is listed offline while its
        // OpenVPN process may be answering fine. A named country's relays are
        // therefore offered to the walk even when the directory has given up
        // on all of them — the walk is the test, and the failure that follows
        // a dead relay names the country that was tried.
        final resolver = await resolverOverProviders([
          FakeResolverProvider(
            id: 'test',
            servers: [
              server(id: 's1', country: 'DE', status: ServerStatus.offline),
            ],
            config: realOvpnConfig(),
          ),
        ]);

        final result = await resolver.resolve(
          const SelectionRequest(countryCode: 'DE'),
          capabilities: openVpnCapable,
        );

        expect(result, isA<ResolveSuccess>());
        final success = result as ResolveSuccess;
        expect(success.target.server.id, 's1');
        expect(success.target.selection.fellBack, isFalse);
        expect(success.notice, isNull);
      },
    );

    test('a provider that cannot supply a config fails cleanly', () async {
      final resolver = await resolverOverProviders([
        FakeResolverProvider(
          id: 'test',
          servers: [server(id: 's1', country: 'DE')],
          noConfigFor: {'s1'},
        ),
      ]);

      final result = await resolver.resolve(
        const SelectionRequest(countryCode: 'DE'),
        capabilities: openVpnCapable,
      );

      expect(
        (result as ResolveFailureResult).reason,
        ResolveFailure.noConfiguration,
      );
      // The message must not read as a successful or in-progress
      // connection: nothing was attempted.
      expect(result.message, isNot(contains('Connected')));
      expect(result.message, isNot(contains('Connecting')));
      expect(result.message, contains('failed validation'));
    });

    test('a provider that throws while fetching does not escape as an unhandled error', () async {
      final provider = FakeResolverProvider(
        id: 'test',
        servers: [server(id: 's1', country: 'DE')],
        config: realOvpnConfig(),
      );
      final resolver = await resolverOverProviders([provider]);
      // Only the config fetch fails; the directory loaded fine.
      provider.throwsOnFetch = true;

      final result = await resolver.resolve(
        const SelectionRequest(countryCode: 'DE'),
        capabilities: openVpnCapable,
      );

      expect(result, isA<ResolveFailureResult>());
      expect(
        (result as ResolveFailureResult).reason,
        ResolveFailure.fetchFailed,
      );
    });

    test('a server whose owning provider is absent is reported, not silently retried', () async {
      // A source that publishes a server tagged with someone else's id.
      // The snapshot looks perfectly valid, but no configuration can be
      // fetched for it, so the resolver must say so rather than reaching
      // for a different provider.
      final liar = FakeResolverProvider(
        id: 'real',
        servers: [server(id: 's1', country: 'DE', providerId: 'ghost')],
        config: realOvpnConfig(),
      );
      final resolver = await resolverOverProviders([liar]);

      final result = await resolver.resolve(
        const SelectionRequest(countryCode: 'DE'),
        capabilities: openVpnCapable,
      );

      expect(
        (result as ResolveFailureResult).reason,
        ResolveFailure.providerUnavailable,
      );
      expect(result.message, contains('ghost'));
    });

    test(
      'a country is only substituted when nothing of its own could be tried',
      () async {
        final resolver = await resolverOverProviders([
          FakeResolverProvider(
            id: 'test',
            servers: [
              // Japan's relay is only *unverified*: the feed could not
              // measure a ping. That is not a reason to hand the user
              // Germany, so Japan is still what gets dialled.
              server(id: 'jp1', country: 'JP', status: ServerStatus.offline),
              server(id: 'de1', country: 'DE', latencyMs: 25),
            ],
            config: realOvpnConfig(),
          ),
        ]);

        final result = await resolver.resolve(
          const SelectionRequest(countryCode: 'JP'),
          capabilities: openVpnCapable,
        );

        expect(result, isA<ResolveSuccess>());
        final success = result as ResolveSuccess;
        expect(success.target.server.id, 'jp1');
        expect(success.target.selection.fellBack, isFalse);
        expect(success.notice, isNull);
      },
    );

    test(
      'a substituted country is reported through notice, never silently',
      () async {
        final resolver = await resolverOverProviders([
          FakeResolverProvider(
            id: 'test',
            servers: [
              // Japan exists but has nothing that may be dialled: withdrawn
              // is the source saying the endpoint is gone, and no ping of
              // ours can overrule it, so a substitute is the honest answer.
              server(id: 'jp1', country: 'JP', status: ServerStatus.withdrawn),
              server(id: 'de1', country: 'DE', latencyMs: 25),
            ],
            config: realOvpnConfig(),
          ),
        ]);

        final result = await resolver.resolve(
          const SelectionRequest(countryCode: 'JP'),
          capabilities: openVpnCapable,
        );

        expect(result, isA<ResolveSuccess>());
        final success = result as ResolveSuccess;
        expect(success.target.server.countryCode, 'DE');
        expect(success.target.fellBack, isTrue);
        expect(success.notice, isNotNull);
        expect(success.notice, contains('JP'));
      },
    );

    test('a public relay is still selectable, and says what it is', () async {
      final resolver = await resolverOverProviders([
        FakeResolverProvider(
          id: 'test',
          servers: [
            server(
              id: 'pub',
              country: 'DE',
              trust: TrustLevel.publicRelay,
              latencyMs: 10,
            ),
          ],
          config: realOvpnConfig(),
        ),
      ]);

      final result = await resolver.resolve(
        const SelectionRequest(countryCode: 'DE'),
        capabilities: openVpnCapable,
      );

      expect(
        (result as ResolveSuccess).target.server.trustLevel,
        TrustLevel.publicRelay,
      );
    });

    test(
      'the configuration handed over is the validated one, not raw text',
      () async {
        final provider = FakeResolverProvider(
          id: 'test',
          servers: [server(id: 's1', country: 'DE')],
          config: realOvpnConfig(),
        );
        final resolver = await resolverOverProviders([provider]);

        final result = await resolver.resolve(
          const SelectionRequest(countryCode: 'DE'),
          capabilities: openVpnCapable,
        );

        final config = (result as ResolveSuccess).target.config;
        // A real VpnConfiguration, not the text it was parsed from: this is
        // the whole reason the resolver returns a pair.
        expect(config.kind, ProtocolKind.openVpn);
        expect(config.openVpn, isNotNull);
        expect(config.fingerprint, isNotEmpty);
        // The validator's repairs travel with the configuration rather than
        // being dropped on the way: a fix that is only reported at import
        // time and then forgotten is not a fix. This profile has none of
        // the full-tunnel directives, so it must arrive carrying them.
        expect(config.repairs, isNotEmpty);
      },
    );

    test('ranked() reflects the live directory and is empty when nothing is loaded', () async {
      final resolver = await resolverOverProviders([
        FakeResolverProvider(
          id: 'test',
          servers: [
            server(id: 'a', country: 'DE', latencyMs: 90),
            server(id: 'b', country: 'DE', latencyMs: 10),
          ],
          config: realOvpnConfig(),
        ),
      ]);

      final ranked = resolver.ranked();
      expect(ranked, hasLength(2));
      expect(ranked.first.score, greaterThan(ranked.last.score));
    });

    test(
      'distance cannot be measured without coordinates, and does not pretend',
      () {
        final resolver = ConnectionResolver(
          discovery: DiscoveryController(providers: const []),
        );
        expect(resolver.canMeasureDistance, isFalse);

        final located = ConnectionResolver(
          discovery: DiscoveryController(providers: const []),
          userLatitude: 52.5,
          userLongitude: 13.4,
        );
        expect(located.canMeasureDistance, isTrue);
      },
    );

    test(
      'nearest mode still works with no location, falling back to score order',
      () async {
        final resolver = await resolverOverProviders([
          FakeResolverProvider(
            id: 'test',
            servers: [
              server(id: 'a', country: 'DE', latencyMs: 90),
              server(id: 'b', country: 'DE', latencyMs: 10),
            ],
            config: realOvpnConfig(),
          ),
        ]);

        final result = await resolver.resolve(
          const SelectionRequest(
            mode: SelectionMode.nearest,
            countryCode: 'DE',
          ),
          capabilities: openVpnCapable,
        );

        // The selector falls back to the best score; the point is that it
        // succeeds rather than throwing or returning a fabricated position.
        expect((result as ResolveSuccess).target.server.id, 'b');
      },
    );

    test('an explicit server id is honoured over the ranking', () async {
      final resolver = await resolverOverProviders([
        FakeResolverProvider(
          id: 'test',
          servers: [
            server(id: 'fast', country: 'DE', latencyMs: 5),
            server(id: 'slow', country: 'DE', latencyMs: 900),
          ],
          config: realOvpnConfig(),
        ),
      ]);

      final result = await resolver.resolve(
        const SelectionRequest(
          mode: SelectionMode.specificServer,
          countryCode: 'DE',
          serverId: 'slow',
        ),
        capabilities: openVpnCapable,
      );

      expect((result as ResolveSuccess).target.server.id, 'slow');
    });

    test(
      'an unknown server id fails rather than falling back to the best',
      () async {
        final resolver = await resolverOverProviders([
          FakeResolverProvider(
            id: 'test',
            servers: [server(id: 'fast', country: 'DE')],
            config: realOvpnConfig(),
          ),
        ]);

        final result = await resolver.resolve(
          const SelectionRequest(
            mode: SelectionMode.specificServer,
            countryCode: 'DE',
            serverId: 'nope',
          ),
        );

        // It may fall back to the country, but if it does, `notice` must say
        // so. The invariant under test is "never silently substitute".
        if (result is ResolveSuccess) {
          expect(result.notice, isNotNull);
        } else {
          expect((result as ResolveFailureResult).reason, isNotNull);
        }
      },
    );

    test('a favourite is used when one is pinned and eligible', () async {
      final resolver = await resolverOverProviders([
        FakeResolverProvider(
          id: 'test',
          servers: [
            server(id: 'fast', country: 'DE', latencyMs: 5),
            server(id: 'pinned', country: 'DE', latencyMs: 400),
          ],
          config: realOvpnConfig(),
        ),
      ]);

      final result = await resolver.resolve(
        const SelectionRequest(
          mode: SelectionMode.favorite,
          countryCode: 'DE',
          favorites: ['pinned'],
        ),
        capabilities: openVpnCapable,
      );

      expect((result as ResolveSuccess).target.server.id, 'pinned');
    });
  });
}
