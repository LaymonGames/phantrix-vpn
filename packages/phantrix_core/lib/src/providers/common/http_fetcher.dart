import '../../core/app_error.dart';

/// A minimal HTTP transport.
///
/// The providers never touch `package:http` directly so that a test can
/// supply a fake and so the app can pin TLS behaviour in one place.
abstract class HttpFetcher {
  /// Performs a GET and returns the body as text.
  ///
  /// Implementations must:
  ///  * follow redirects only after re-validating the scheme is https;
  ///  * cap the response body (see `maxBodyBytes`);
  ///  * raise [AppError] on any failure instead of throwing a raw
  ///    platform exception.
  Future<String> get(Uri url);

  /// Largest body the app will accept, which stops a compromised feed from
  /// exhausting memory.
  int get maxBodyBytes;
}

/// Raised by [HttpFetcher] implementations when the body is too large.
class BodyTooLargeException implements Exception {
  const BodyTooLargeException(this.actual, this.limit);

  final int actual;
  final int limit;

  AppError asError() => AppError(
    group: ErrorGroup.provider,
    code: 'http.body_too_large',
    message:
        'The server list was larger than the '
        '${(limit / 1024).round()} KB limit and was rejected.',
  );
}

/// Optional line-streaming capability for large text feeds.
///
/// Providers can consume a bounded prefix of a feed and cancel the response as
/// soon as they have enough usable records, instead of downloading and keeping
/// the entire payload in memory. Implementations must apply the same HTTPS,
/// redirect, timeout, and response-size rules as [HttpFetcher.get].
abstract interface class HttpLineFetcher {
  Stream<String> getLines(Uri url);
}
