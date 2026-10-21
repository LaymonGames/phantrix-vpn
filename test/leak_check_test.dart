import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:phantrix/net/app_http_fetcher.dart';
import 'package:phantrix/vpn/leak_check.dart';

/// Verification is the gate between "the tunnel started" and "the user is
/// told they are protected". These tests attack that gate: each one tries a
/// way of getting `verified: true` without a real, working, leak-free
/// tunnel.
///
/// The real `AppHttpFetcher` runs throughout, with a mocked `http.Client`
/// underneath it, so the production parsing, status handling and error
/// conversion are all exercised and only the socket is absent.
///
/// `wait: _noDelay` removes the re-read pause: verification retries an
/// unchanged or unreachable reading a few times before judging it (a live
/// run showed the first read racing the tunnel's route installation), and
/// without this the retries would run in real time and every negative test
/// would take seconds.
LeakCheck _serving(String body, {Future<void> Function(Duration)? wait}) =>
    LeakCheck(
      fetcher: _clientReturning((_) async => http.Response(body, 200)),
      wait: wait ?? _noDelay,
    );

Future<void> _noDelay(Duration _) async {}

LeakCheck _alwaysFails() => LeakCheck(
  fetcher: _clientReturning((_) async => http.Response('down', 503)),
  wait: _noDelay,
);

/// Answers with each response in turn, then 503 forever after.
LeakCheck _sequenced(List<http.Response Function()> responses) {
  var index = 0;
  return LeakCheck(
    fetcher: _clientReturning((_) async {
      final current = index++;
      return current < responses.length
          ? responses[current]()
          : http.Response('', 503);
    }),
    wait: _noDelay,
  );
}

AppHttpFetcher _clientReturning(
  Future<http.Response> Function(http.Request) handler,
) => AppHttpFetcher(client: MockClient(handler));

void main() {
  final now = DateTime(2026, 6, 1, 12, 0, 0);

  test('bounds the pre-tunnel IP probe to one total deadline', () async {
    var requestCount = 0;
    final check = LeakCheck(
      fetcher: AppHttpFetcher(
        client: MockClient((_) async {
          requestCount++;
          await Future<void>.delayed(const Duration(milliseconds: 40));
          return http.Response('198.51.100.9', 200);
        }),
      ),
      endpoints: [
        Uri.parse('https://first.example/ip'),
        Uri.parse('https://second.example/ip'),
        Uri.parse('https://third.example/ip'),
      ],
      wait: _noDelay,
    );
    final watch = Stopwatch()..start();

    final result = await check.currentIp(
      timeout: const Duration(milliseconds: 5),
    );

    expect(result, isNull);
    // The providers are asked together — a slow first one must not spend
    // the whole budget alone. The deadline still bounds everything.
    expect(requestCount, 3);
    expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });

  test('the fastest endpoint answer is read in endpoint order', () async {
    final check = LeakCheck(
      fetcher: AppHttpFetcher(
        client: MockClient((request) async {
          final howFast = request.url.host.startsWith('slow')
              ? const Duration(milliseconds: 80)
              : const Duration(milliseconds: 5);
          await Future<void>.delayed(howFast);
          return http.Response('203.0.113.9', 200);
        }),
      ),
      endpoints: [Uri.parse('https://slow.example/ip')],
      wait: _noDelay,
    );

    final result = await check.currentIp();
    expect(result, '203.0.113.9');
    await check.close();
  });

  group('extractAddress', () {
    test('reads a JSON ip field', () {
      expect(LeakCheck.extractAddress('{"ip":"203.0.113.9"}'), '203.0.113.9');
    });

    test('reads a bare address line', () {
      expect(LeakCheck.extractAddress('203.0.113.9\n'), '203.0.113.9');
    });

    test('ignores a trailing banner rather than reading it as the address', () {
      expect(
        LeakCheck.extractAddress('203.0.113.9\n<html>captive portal</html>'),
        '203.0.113.9',
      );
    });

    test('reads an IPv6 answer', () {
      expect(LeakCheck.extractAddress('{"ip":"2001:db8::1"}'), '2001:db8::1');
    });

    test('rejects an empty body', () {
      expect(LeakCheck.extractAddress('   '), isNull);
    });

    test(
      'rejects a captive-portal page instead of passing it as an address',
      () {
        // The critical case: a portal response that differs from the
        // baseline would otherwise read as "the address changed" and
        // wrongly pass verification.
        expect(
          LeakCheck.extractAddress(
            '<html><body>Sign in to continue</body></html>',
          ),
          isNull,
        );
        expect(LeakCheck.extractAddress('{"ip":"please log in"}'), isNull);
      },
    );

    test('rejects malformed JSON rather than guessing', () {
      expect(LeakCheck.extractAddress('{"ip":'), isNull);
    });
  });

  group('isPlausibleAddress', () {
    test('accepts real addresses', () {
      for (final good in [
        '8.8.8.8',
        '203.0.113.9',
        '255.255.255.255',
        '0.0.0.0',
        '::1',
        '2001:db8::1',
        'fe80::1',
      ]) {
        expect(LeakCheck.isPlausibleAddress(good), isTrue, reason: good);
      }
    });

    test('rejects out-of-range octets', () {
      expect(LeakCheck.isPlausibleAddress('192.0.2.256'), isFalse);
      expect(LeakCheck.isPlausibleAddress('192.0.2.-1'), isFalse);
    });

    test('rejects the wrong number of octets', () {
      expect(LeakCheck.isPlausibleAddress('192.0.2'), isFalse);
      expect(LeakCheck.isPlausibleAddress('192.0.2.1.1'), isFalse);
    });

    test('rejects prose that merely looks address-shaped', () {
      for (final bad in [
        'hello world',
        '999.999.999.999',
        'localhost',
        'a.b.c.d',
        ':::',
        'a:b:c',
        ':1:2:3:4:5:6:7:8',
        '1:2:3:4:5:6:7:8:',
        '+1.2.3.4',
      ]) {
        expect(LeakCheck.isPlausibleAddress(bad), isFalse, reason: bad);
      }
    });

    test('rejects a word containing a colon', () {
      expect(LeakCheck.isPlausibleAddress('error:timeout'), isFalse);
    });
  });

  group('sameAddress', () {
    test('is true for identical strings', () {
      expect(LeakCheck.sameAddress('203.0.113.9', '203.0.113.9'), isTrue);
    });

    test('treats the IPv4-mapped form as the same address', () {
      expect(
        LeakCheck.sameAddress('::ffff:203.0.113.9', '203.0.113.9'),
        isTrue,
      );
    });

    test('is false for genuinely different addresses', () {
      expect(LeakCheck.sameAddress('203.0.113.9', '198.51.100.4'), isFalse);
    });

    test('compares expanded and compressed IPv6 by value', () {
      expect(
        LeakCheck.sameAddress('2001:0DB8:0:0:0:0:0:1', '2001:db8::1'),
        isTrue,
      );
      expect(
        LeakCheck.sameAddress('0:0:0:0:0:ffff:cb00:7109', '203.0.113.9'),
        isTrue,
      );
    });
  });

  group('verify refuses without a handshake', () {
    test('no handshake at all is not connected', () async {
      final check = _serving('{"ip":"203.0.113.9"}');
      final outcome = await check.verify(
        baseline: '198.51.100.4',
        handshakeAt: null,
        now: now,
      );
      expect(outcome.verified, isFalse);
      expect(outcome.handshakeObserved, isFalse);
      expect(outcome.message, contains('handshake'));
      await check.close();
    });

    test('a fresh handshake plus a changed address is connected', () async {
      final check = _serving('{"ip":"203.0.113.9"}');
      final outcome = await check.verify(
        baseline: '198.51.100.4',
        handshakeAt: now.subtract(const Duration(seconds: 20)),
        now: now,
      );
      expect(outcome.verified, isTrue);
      expect(outcome.publicIp, '203.0.113.9');
      expect(outcome.handshakeFresh, isTrue);
      await check.close();
    });
  });

  group('verify refuses a stale handshake', () {
    test('a future handshake cannot verify the connection', () async {
      final check = _serving('{"ip":"203.0.113.9"}');
      final outcome = await check.verify(
        baseline: '198.51.100.4',
        handshakeAt: now.add(const Duration(minutes: 1)),
        now: now,
      );
      expect(outcome.verified, isFalse);
      expect(outcome.handshakeFresh, isFalse);
      expect(outcome.message, contains('future'));
      await check.close();
    });

    test('the classic bug: interface up, peer long gone', () async {
      // A tunnel whose interface is still nominally up but whose peer
      // stopped answering. Reporting "connected" here is the single most
      // misleading thing a VPN can do.
      final check = _serving('{"ip":"203.0.113.9"}');
      final outcome = await check.verify(
        baseline: '198.51.100.4',
        handshakeAt: now.subtract(const Duration(minutes: 30)),
        now: now,
      );
      expect(outcome.verified, isFalse);
      expect(outcome.handshakeObserved, isTrue);
      expect(outcome.handshakeFresh, isFalse);
      expect(outcome.message, contains('30 minutes ago'));
      await check.close();
    });

    test('a handshake just inside the window is accepted', () async {
      final check = _serving('{"ip":"203.0.113.9"}');
      final outcome = await check.verify(
        baseline: '198.51.100.4',
        handshakeAt: now.subtract(const Duration(minutes: 2, seconds: 30)),
        now: now,
      );
      expect(outcome.verified, isTrue);
      await check.close();
    });

    test('a handshake just outside the window is rejected', () async {
      final check = _serving('{"ip":"203.0.113.9"}');
      final outcome = await check.verify(
        baseline: '198.51.100.4',
        handshakeAt: now.subtract(const Duration(minutes: 3, seconds: 1)),
        now: now,
      );
      expect(outcome.verified, isFalse);
      await check.close();
    });
  });

  group('verify catches a real leak', () {
    test(
      'the address did not change, so the tunnel is not carrying traffic',
      () async {
        final check = _serving('{"ip":"198.51.100.4"}');
        final outcome = await check.verify(
          baseline: '198.51.100.4',
          handshakeAt: now.subtract(const Duration(seconds: 10)),
          now: now,
        );
        expect(outcome.verified, isFalse);
        expect(outcome.message, contains('did not change'));
        expect(outcome.publicIp, '198.51.100.4');
        await check.close();
      },
    );

    test('an unreachable address service is not treated as a pass', () async {
      // "Could not measure" must never become "no leak".
      final check = _alwaysFails();
      final outcome = await check.verify(
        baseline: '198.51.100.4',
        handshakeAt: now.subtract(const Duration(seconds: 10)),
        now: now,
      );
      expect(outcome.verified, isFalse);
      expect(outcome.message, contains('no external address service'));
      await check.close();
    });

    test(
      'a captive portal response is not treated as a changed address',
      () async {
        // The attack: a network that returns a portal page. The baseline was
        // the real address; the "new" answer is not an address at all. A
        // naive implementation sees two different strings and passes.
        final check = _serving('{"ip":"<b>Portal</b>"}');
        final outcome = await check.verify(
          baseline: '198.51.100.4',
          handshakeAt: now.subtract(const Duration(seconds: 10)),
          now: now,
        );
        expect(outcome.verified, isFalse);
        await check.close();
      },
    );
  });

  group('verify re-reads before judging an unchanged address', () {
    // The race this group exists for: the engine reports the handshake the
    // instant TLS completes, but the routes carrying traffic through the
    // tunnel land just after. A live run probed in that window, read the
    // pre-tunnel address, and refused a tunnel that was actually working —
    // the same relay, re-attempted seconds later, verified and carried
    // traffic. One reading is not evidence; a reading that stays unchanged
    // across several seconds of trying is.
    test(
      'a first reading that matches the baseline is retried, not judged',
      () async {
        final check = _sequenced([
          // The race: the first read still egresses outside the tunnel.
          () => http.Response('{"ip":"198.51.100.4"}', 200),
          // Routes land; the next read sees the relay's address.
          () => http.Response('{"ip":"203.0.113.9"}', 200),
        ]);
        final outcome = await check.verify(
          baseline: '198.51.100.4',
          handshakeAt: now.subtract(const Duration(seconds: 5)),
          now: now,
        );
        expect(outcome.verified, isTrue);
        expect(outcome.publicIp, '203.0.113.9');
        await check.close();
      },
    );

    test('an unreachable first read is retried, not judged', () async {
      // Same window, different symptom: with routes half-installed the
      // probe cannot reach any address service. One pass would report
      // "could not be verified" for a tunnel that is seconds from
      // working.
      final check = _sequenced([
        // The whole first pass fails: nothing reachable yet.
        () => http.Response('', 503),
        () => http.Response('', 503),
        () => http.Response('', 503),
        // The re-read finds the service — and the tunnel's address.
        () => http.Response('{"ip":"203.0.113.9"}', 200),
      ]);
      final outcome = await check.verify(
        baseline: '198.51.100.4',
        handshakeAt: now.subtract(const Duration(seconds: 5)),
        now: now,
      );
      expect(outcome.verified, isTrue);
      expect(outcome.publicIp, '203.0.113.9');
      await check.close();
    });

    test('the retries are bounded and pause between reads', () async {
      // A tunnel that really is leaking must still be refused — and
      // refused promptly. The re-reads stop at LeakCheck.maxReads and
      // the pause between them is real (recorded here, injected as a
      // no-op so the test does not sleep).
      final pauses = <Duration>[];
      var calls = 0;
      final check = LeakCheck(
        fetcher: _clientReturning((_) async {
          calls++;
          return http.Response('{"ip":"198.51.100.4"}', 200);
        }),
        wait: (delay) async => pauses.add(delay),
      );
      final outcome = await check.verify(
        baseline: '198.51.100.4',
        handshakeAt: now.subtract(const Duration(seconds: 5)),
        now: now,
      );
      expect(outcome.verified, isFalse);
      expect(outcome.message, contains('did not change'));
      // One read per attempt against a single reachable endpoint, and
      // one pause between each pair of attempts.
      expect(calls, LeakCheck.maxReads);
      expect(pauses, hasLength(LeakCheck.maxReads - 1));
      await check.close();
    });

    test(
      'a changed address is accepted on the first read, without retries',
      () async {
        // Nothing that proves the tunnel works needs a second opinion;
        // retrying would only delay a good result.
        final pauses = <Duration>[];
        var calls = 0;
        final check = LeakCheck(
          fetcher: _clientReturning((_) async {
            calls++;
            return http.Response('{"ip":"203.0.113.9"}', 200);
          }),
          wait: (delay) async => pauses.add(delay),
        );
        final outcome = await check.verify(
          baseline: '198.51.100.4',
          handshakeAt: now.subtract(const Duration(seconds: 5)),
          now: now,
        );
        expect(outcome.verified, isTrue);
        expect(calls, 1);
        expect(pauses, isEmpty);
        await check.close();
      },
    );
  });

  group('verify without a baseline', () {
    test('missing routing evidence never becomes success', () async {
      final check = _serving('{"ip":"203.0.113.9"}');
      final outcome = await check.verify(
        baseline: null,
        handshakeAt: now.subtract(const Duration(seconds: 10)),
        now: now,
      );
      expect(outcome.verified, isFalse);
      expect(outcome.message, contains('could not be read'));
      expect(outcome.message, contains('handshake'));
      await check.close();
    });
  });

  test(
    'switching address families is not evidence of a working route',
    () async {
      final check = _serving('{"ip":"203.0.113.9"}');
      final outcome = await check.verify(
        baseline: '2001:db8::1',
        handshakeAt: now.subtract(const Duration(seconds: 10)),
        now: now,
      );
      expect(outcome.verified, isFalse);
      expect(outcome.message, contains('different IP families'));
      await check.close();
    },
  );

  group('endpoint failover', () {
    test('one provider being down does not block verification', () async {
      final check = _sequenced([
        () => http.Response('nope', 503),
        () => http.Response('{"ip":"203.0.113.9"}', 200),
        () => http.Response('{"ip":"203.0.113.9"}', 200),
      ]);
      final outcome = await check.verify(
        baseline: '198.51.100.4',
        handshakeAt: now.subtract(const Duration(seconds: 10)),
        now: now,
      );
      expect(outcome.verified, isTrue);
      expect(outcome.endpointHost, isNotNull);
      await check.close();
    });
  });
}
