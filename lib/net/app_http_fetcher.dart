import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:phantrix_core/phantrix_core.dart';

/// The app's only outbound HTTP path.
///
/// Every request goes through here so HTTPS, redirect policy, response-size
/// limits, and failure handling stay consistent. The line-streaming API lets
/// large feeds be consumed incrementally and cancelled as soon as enough
/// usable rows have been collected.
class AppHttpFetcher implements HttpFetcher, HttpLineFetcher {
  AppHttpFetcher({
    required this.client,
    this.timeout = const Duration(seconds: 30),
    this.maxRedirects = 3,
    this.maxBodyBytes = 64 * 1024 * 1024,
  });

  /// The transport. Exposed so a test can assert on the requests made.
  final http.Client client;

  final Duration timeout;
  final int maxRedirects;

  /// Largest body accepted. The limit is enforced while bytes arrive.
  @override
  final int maxBodyBytes;

  /// A fetcher with its own client, for callers that do not inject one.
  ///
  /// The client is not shared, so the caller is responsible for closing it
  /// via [close] when finished.
  factory AppHttpFetcher.owned({
    Duration timeout = const Duration(seconds: 30),
    int maxBodyBytes = 64 * 1024 * 1024,
  }) => AppHttpFetcher(
    client: http.Client(),
    timeout: timeout,
    maxBodyBytes: maxBodyBytes,
  );

  @override
  Future<String> get(Uri url) async {
    final lines = <String>[];
    await for (final line in getLines(url)) {
      lines.add(line);
    }
    return lines.join('\n');
  }

  @override
  Stream<String> getLines(Uri url) async* {
    if (url.scheme != 'https') {
      throw const AppError(
        group: ErrorGroup.network,
        code: 'http.plaintext_rejected',
        message: 'Only encrypted https requests are allowed.',
      );
    }

    final watch = Stopwatch()..start();
    var current = url;
    http.StreamedResponse? response;

    for (var hop = 0; hop <= maxRedirects; hop++) {
      final remaining = timeout - watch.elapsed;
      if (remaining <= Duration.zero) {
        throw const AppError(
          group: ErrorGroup.network,
          code: 'http.timeout',
          message: 'The server took too long to answer.',
        );
      }

      final http.StreamedResponse streamed;
      try {
        final request = http.Request('GET', current)
          ..followRedirects = false
          ..maxRedirects = 0
          ..headers.addAll(const {
            'Accept': 'text/csv, text/plain;q=0.9, */*;q=0.5',
            'User-Agent': 'Phantrix/1.0',
          });
        streamed = await client.send(request).timeout(remaining);
      } on TimeoutException {
        throw const AppError(
          group: ErrorGroup.network,
          code: 'http.timeout',
          message: 'The server took too long to answer.',
        );
      } on AppError {
        rethrow;
      } catch (error) {
        throw AppError(
          group: ErrorGroup.network,
          code: 'http.unreachable',
          message: 'Could not reach the server list. Check your connection.',
          detail: {'cause': error.runtimeType.toString()},
        );
      }

      if (_isRedirect(streamed.statusCode)) {
        final location = streamed.headers['location'];
        await _cancelResponse(streamed);
        if (location == null || location.isEmpty) {
          throw const AppError(
            group: ErrorGroup.network,
            code: 'http.bad_redirect',
            message: 'The server sent a redirect with no destination.',
          );
        }
        final next = current.resolve(location);
        if (next.scheme != 'https') {
          throw const AppError(
            group: ErrorGroup.network,
            code: 'http.plaintext_redirect',
            message: 'The server tried to redirect to an unencrypted address.',
          );
        }
        current = next;
        continue;
      }

      if (streamed.statusCode != 200) {
        await _cancelResponse(streamed);
        throw AppError(
          group: ErrorGroup.network,
          code: 'http.status_${streamed.statusCode}',
          message: 'The server list request was refused.',
        );
      }

      response = streamed;
      break;
    }

    final streamed = response;
    if (streamed == null) {
      throw const AppError(
        group: ErrorGroup.network,
        code: 'http.too_many_redirects',
        message: 'The server list redirected too many times.',
      );
    }

    var byteCount = 0;
    final boundedBytes = streamed.stream.transform(
      StreamTransformer<List<int>, List<int>>.fromBind((source) async* {
        await for (final chunk in source) {
          byteCount += chunk.length;
          if (byteCount > maxBodyBytes) {
            throw BodyTooLargeException(byteCount, maxBodyBytes).asError();
          }
          if (watch.elapsed >= timeout) {
            throw TimeoutException(
              'Response body exceeded the request timeout.',
            );
          }
          yield chunk;
        }
      }),
    );

    final remaining = timeout - watch.elapsed;
    if (remaining <= Duration.zero) {
      await _cancelResponse(streamed);
      throw const AppError(
        group: ErrorGroup.network,
        code: 'http.timeout',
        message: 'The server took too long to answer.',
      );
    }

    try {
      final decoded = const Utf8Decoder(allowMalformed: false)
          .bind(boundedBytes.timeout(remaining));
      await for (final line in const LineSplitter().bind(decoded)) {
        yield line;
      }
    } on TimeoutException {
      throw const AppError(
        group: ErrorGroup.network,
        code: 'http.timeout',
        message: 'The server took too long to answer.',
      );
    } on AppError {
      rethrow;
    } on FormatException {
      throw const AppError(
        group: ErrorGroup.parse,
        code: 'http.not_utf8',
        message: 'The server list was not valid text and was rejected.',
      );
    } catch (error) {
      throw AppError(
        group: ErrorGroup.network,
        code: 'http.unreachable',
        message: 'Could not read the server list. Check your connection.',
        detail: {'cause': error.runtimeType.toString()},
      );
    }
  }

  Future<void> _cancelResponse(http.StreamedResponse response) async {
    final subscription = response.stream.listen((_) {});
    await subscription.cancel();
  }

  static bool _isRedirect(int status) =>
      status == 301 ||
      status == 302 ||
      status == 303 ||
      status == 307 ||
      status == 308;

  /// Releases the underlying client.
  void close() => client.close();
}
