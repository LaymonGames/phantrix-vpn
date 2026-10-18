import 'package:phantrix_core/src/model/server_metrics.dart';
import 'package:phantrix_core/src/model/server_status.dart';
import 'package:phantrix_core/src/model/trust_level.dart';
import 'package:phantrix_core/src/model/vpn_server.dart';
import 'package:phantrix_core/src/protocol/protocol_kind.dart';
import 'package:phantrix_core/src/scoring/selection_mode.dart';
import 'package:phantrix_core/src/scoring/server_scorer.dart';
import 'package:phantrix_core/src/scoring/server_selector.dart';
import 'package:test/test.dart';

VpnServer server(
  String id, {
  int? latencyMs = 100,
  int? activeUsers,
  ServerStatus status = ServerStatus.online,
  int successCount = 0,
  int failureCount = 0,
  int consecutiveFailures = 0,
  double? uptimeRatio = 0.9,
  double? latitude,
  double? longitude,
}) => VpnServer(
  id: id,
  hostname: '$id.example.net',
  hostAddress: '203.0.113.$id',
  port: 51820,
  protocol: ProtocolKind.wireGuard,
  trustLevel: TrustLevel.publicRelay,
  status: status,
  countryCode: 'JP',
  providerId: 'test',
  latitude: latitude,
  longitude: longitude,
  metrics: ServerMetrics(
    latencyMs: latencyMs,
    activeUsers: activeUsers,
    uptimeRatio: uptimeRatio,
    successCount: successCount,
    failureCount: failureCount,
    consecutiveFailures: consecutiveFailures,
  ),
);

void main() {
  group('ServerScorer', () {
    const scorer = ServerScorer();
    const context = ScoreContext();

    test('a low-latency server outranks a high-latency one', () {
      final fast = scorer.score(server('1', latencyMs: 20), context);
      final slow = scorer.score(server('2', latencyMs: 800), context);
      expect(fast, greaterThan(slow));
    });

    test('an offline server is ineligible', () {
      expect(
        scorer.score(server('x', status: ServerStatus.offline), context),
        0,
      );
      expect(
        ServerScorer.isEligible(server('x', status: ServerStatus.offline)),
        isFalse,
      );
    });

    test('a server that keeps failing is skipped', () {
      expect(
        scorer.score(
          server('x', consecutiveFailures: ServerScorer.maxConsecutiveFailures),
          context,
        ),
        0,
      );
    });

    test('a degraded server can still be chosen', () {
      expect(
        server('x', status: ServerStatus.degraded).status.isUsable,
        isTrue,
      );
    });

    test(
      'an unmeasured latency does not score better than a measured good one',
      () {
        final measured = scorer.score(server('a', latencyMs: 30), context);
        final unknown = scorer.score(server('b', latencyMs: null), context);
        expect(measured, greaterThan(unknown));
      },
    );

    test('an overloaded relay scores below a quiet one', () {
      final quiet = scorer.score(server('a', activeUsers: 5), context);
      final busy = scorer.score(server('b', activeUsers: 250), context);
      expect(quiet, greaterThan(busy));
    });

    test('distance only breaks ties; it never overrides latency', () {
      const weighted = ServerScorer();
      // Far but fast beats near but slow.
      final farFast = weighted.score(
        server('a', latencyMs: 10, latitude: -30, longitude: 140),
        const ScoreContext(userLatitude: 60, userLongitude: 20),
      );
      final nearSlow = weighted.score(
        server('b', latencyMs: 700, latitude: 61, longitude: 21),
        const ScoreContext(userLatitude: 60, userLongitude: 20),
      );
      expect(farFast, greaterThan(nearSlow));
    });

    test('the score is stable and within bounds', () {
      for (var i = 0; i < 32; i++) {
        final score = scorer.score(server('$i', latencyMs: i * 20), context);
        expect(score, inInclusiveRange(0, 100));
      }
    });
  });

  group('ServerSelector', () {
    const selector = ServerSelector();
    const context = ScoreContext();

    test('recommended picks the best measured server', () {
      final servers = [
        server('slow', latencyMs: 500),
        server('best', latencyMs: 10),
        server('mid', latencyMs: 200),
      ];
      final selection = selector.select(
        servers,
        const SelectionRequest(mode: SelectionMode.recommended),
        context,
      );
      expect(selection!.server.id, 'best');
      expect(selection.explanation, isNotEmpty);
    });

    test('fastest and recommended agree when latency dominates', () {
      final servers = [server('a', latencyMs: 300), server('b', latencyMs: 40)];
      final a = selector.select(
        servers,
        const SelectionRequest(mode: SelectionMode.fastest),
        context,
      );
      expect(a!.server.id, 'b');
    });

    test('random is reproducible with a seed', () {
      final servers = List.generate(
        5,
        (i) => server('s$i', latencyMs: 10 * (i + 1)),
      );
      final first = selector.select(
        servers,
        const SelectionRequest(mode: SelectionMode.random, seed: 42),
        context,
      );
      final second = selector.select(
        servers,
        const SelectionRequest(mode: SelectionMode.random, seed: 42),
        context,
      );
      expect(first!.server.id, second!.server.id);
    });

    test('nearest uses distance when coordinates are available', () {
      final servers = [
        server('far', latencyMs: 10, latitude: -33, longitude: 151),
        server('near', latencyMs: 400, latitude: 61, longitude: 21),
      ];
      final ctx = const ScoreContext(userLatitude: 60, userLongitude: 21);
      final selection = selector.select(
        servers,
        const SelectionRequest(mode: SelectionMode.nearest),
        ctx,
      );
      expect(selection!.server.id, 'near');
    });

    test('healthiest prefers the server with the better record', () {
      final servers = [
        server('flaky', latencyMs: 10, successCount: 1, failureCount: 8),
        server('solid', latencyMs: 200, successCount: 9, failureCount: 0),
      ];
      final selection = selector.select(
        servers,
        const SelectionRequest(mode: SelectionMode.healthiest),
        context,
      );
      expect(selection!.server.id, 'solid');
    });

    test('a specific server is honoured when eligible', () {
      final servers = [server('a'), server('b'), server('c')];
      final selection = selector.select(
        servers,
        const SelectionRequest(
          mode: SelectionMode.specificServer,
          serverId: 'c',
        ),
        context,
      );
      expect(selection!.server.id, 'c');
      expect(selection.fellBack, isFalse);
    });

    test('returns null when nothing is eligible', () {
      final servers = [server('a', status: ServerStatus.offline)];
      expect(
        selector.select(servers, const SelectionRequest(), context),
        isNull,
      );
    });

    test('selecting an unavailable country falls back and says so', () {
      final servers = [
        VpnServer(
          id: 'jp',
          hostname: 'jp.example.net',
          hostAddress: '203.0.113.1',
          port: 51820,
          protocol: ProtocolKind.wireGuard,
          trustLevel: TrustLevel.publicRelay,
          status: ServerStatus.online,
          countryCode: 'JP',
          providerId: 'test',
          metrics: const ServerMetrics(latencyMs: 20, uptimeRatio: 0.9),
        ),
      ];
      final selection = selector.selectForCountry(
        servers,
        'DE',
        const SelectionRequest(),
        context,
      );
      expect(selection!.fellBack, isTrue);
      expect(selection.fallbackCause, isNotNull);
      expect(selection.explanation, contains('DE'));
    });

    test('selecting an available country never falls back', () {
      final servers = [
        server('jp', latencyMs: 50),
        VpnServer(
          id: 'de',
          hostname: 'de.example.net',
          hostAddress: '203.0.113.2',
          port: 51820,
          protocol: ProtocolKind.wireGuard,
          trustLevel: TrustLevel.publicRelay,
          status: ServerStatus.online,
          countryCode: 'DE',
          providerId: 'test',
          metrics: const ServerMetrics(latencyMs: 200, uptimeRatio: 0.5),
        ),
      ];
      final selection = selector.selectForCountry(
        servers,
        'DE',
        const SelectionRequest(),
        context,
      );
      expect(selection!.server.id, 'de');
      expect(selection.fellBack, isFalse);
    });

    test('a server beyond the request distance is not considered', () {
      final servers = [
        server('near', latencyMs: 10, latitude: 60, longitude: 21),
        server('far', latencyMs: 5, latitude: -33, longitude: 151),
      ];
      const ctx = ScoreContext(userLatitude: 60, userLongitude: 21);
      // `far` is thousands of kilometres away, so a 5000 km ceiling must
      // drop it even though it has the better latency.
      final selection = selector.select(
        servers,
        const SelectionRequest(maxDistanceKm: 5000),
        ctx,
      );
      expect(selection!.server.id, 'near');
    });

    test('a server with no coordinates is never dropped on distance', () {
      final servers = [
        server('placed', latencyMs: 200, latitude: 60, longitude: 21),
        server('unplaced', latencyMs: 10),
      ];
      const ctx = ScoreContext(userLatitude: 60, userLongitude: 21);
      final selection = selector.select(
        servers,
        const SelectionRequest(maxDistanceKm: 100),
        ctx,
      );
      // `unplaced` cannot be measured, so distance must not exclude it; it
      // wins on latency.
      expect(selection!.server.id, 'unplaced');
    });

    test('a favorite is chosen when it is eligible', () {
      final servers = [
        server('best', latencyMs: 5),
        server('fav', latencyMs: 300),
      ];
      final selection = selector.select(
        servers,
        const SelectionRequest(
          mode: SelectionMode.favorite,
          favorites: ['fav'],
        ),
        context,
      );
      expect(selection!.server.id, 'fav');
    });
  });
}
