import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:phantrix_core/phantrix_core.dart';

import 'package:phantrix/net/app_http_fetcher.dart';

void main() {
  group('AppHttpFetcher', () {
    test('fetches a text feed with the expected headers', () async {
      late http.Request captured;
      final fetcher = AppHttpFetcher(
        client: MockClient((request) async {
          captured = request;
          return http.Response('feed-content', 200);
        }),
      );
      addTearDown(fetcher.close);

      expect(
        await fetcher.get(Uri.parse('https://example.test/feed')),
        'feed-content',
      );
      expect(captured.followRedirects, isFalse);
      expect(captured.headers['Accept'], contains('text/csv'));
      expect(captured.headers['User-Agent'], 'Phantrix/1.0');
    });

    test('exposes feed lines incrementally as UTF-8 text', () async {
      final fetcher = AppHttpFetcher(
        client: MockClient(
          (_) async => http.Response('# header\nrelay-one\nrelay-two\n', 200),
        ),
      );
      addTearDown(fetcher.close);

      expect(
        await fetcher.getLines(Uri.parse('https://example.test/feed')).toList(),
        ['# header', 'relay-one', 'relay-two'],
      );
    });

    test('rejects oversized response bodies while streaming', () async {
      final fetcher = AppHttpFetcher(
        client: MockClient((_) async => http.Response('12345', 200)),
        maxBodyBytes: 4,
      );
      addTearDown(fetcher.close);

      try {
        await fetcher.get(Uri.parse('https://example.test/feed'));
        fail('Expected oversized body to be rejected.');
      } on AppError catch (error) {
        expect(error.code, 'http.body_too_large');
      }
    });

    test('refuses an HTTPS request that redirects to HTTP', () async {
      var requestCount = 0;
      final fetcher = AppHttpFetcher(
        client: MockClient((request) async {
          requestCount++;
          return http.Response(
            '',
            302,
            headers: {'location': 'http://example.test/insecure'},
          );
        }),
      );
      addTearDown(fetcher.close);

      try {
        await fetcher.get(Uri.parse('https://example.test/feed'));
        fail('Expected an insecure redirect to be rejected.');
      } on AppError catch (error) {
        expect(error.code, 'http.plaintext_redirect');
      }
      expect(requestCount, 1);
    });

    test('rejects a non-HTTPS URL before making a request', () async {
      var requestCount = 0;
      final fetcher = AppHttpFetcher(
        client: MockClient((_) async {
          requestCount++;
          return http.Response('', 200);
        }),
      );
      addTearDown(fetcher.close);

      try {
        await fetcher.get(Uri.parse('http://example.test/feed'));
        fail('Expected plaintext URL to be rejected.');
      } on AppError catch (error) {
        expect(error.code, 'http.plaintext_rejected');
      }
      expect(requestCount, 0);
    });
  });
}
