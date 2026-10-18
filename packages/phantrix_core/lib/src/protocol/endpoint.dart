import '../core/app_error.dart';
import '../core/result.dart';

/// A WireGuard peer endpoint (`host:port`, `[ipv6]:port`).
///
/// The app never asks the user to type one; they are produced by server
/// providers. Validation is still mandatory because a malformed endpoint is
/// the single most common cause of a connection that hangs instead of
/// failing.
class WgEndpoint {
  const WgEndpoint(this.host, this.port);

  final String host;
  final int port;

  static const int defaultPort = 51820;
  static const int minPort = 1;
  static const int maxPort = 65535;

  static Result<WgEndpoint> parse(
    String raw, {
    int defaultPort = WgEndpoint.defaultPort,
  }) {
    var value = raw.trim();
    if (value.isEmpty) {
      return _fail('endpoint.empty', 'Endpoint is empty.');
    }
    value = value.replaceAll(RegExp(r'/(udp|tcp)$', caseSensitive: false), '');

    String host;
    var port = defaultPort;

    if (value.startsWith('[')) {
      final close = value.indexOf(']');
      if (close < 2) {
        return _fail(
          'endpoint.bracket',
          'IPv6 endpoint must be written as [address]:port.',
        );
      }
      host = value.substring(1, close);
      final rest = value.substring(close + 1);
      if (rest.isNotEmpty) {
        if (!rest.startsWith(':')) {
          return _fail(
            'endpoint.format',
            'Endpoint must be written as [address]:port.',
          );
        }
        final parsedPort = _parsePort(rest.substring(1));
        final decodedPort = parsedPort.valueOrNull;
        final portError = parsedPort.errorOrNull;
        if (decodedPort != null) {
          port = decodedPort;
        } else if (portError != null) {
          return Err(portError);
        }
      }
    } else {
      final colonCount = ':'.allMatches(value).length;
      if (colonCount == 0) {
        host = value;
      } else if (colonCount == 1) {
        final index = value.indexOf(':');
        host = value.substring(0, index);
        final parsedPort = _parsePort(value.substring(index + 1));
        final decodedPort = parsedPort.valueOrNull;
        final portError = parsedPort.errorOrNull;
        if (decodedPort != null) {
          port = decodedPort;
        } else if (portError != null) {
          return Err(portError);
        }
      } else if (colonCount <= 7 &&
          RegExp(r'^[0-9A-Fa-f:]+$').hasMatch(value)) {
        host = value;
      } else {
        return _fail(
          'endpoint.format',
          'Endpoint must be host:port or [ipv6]:port.',
        );
      }
    }

    if (host.isEmpty) {
      return _fail('endpoint.host', 'Endpoint host is empty.');
    }
    if (host.length > 253) {
      return _fail('endpoint.host_long', 'Endpoint hostname is too long.');
    }
    if (!_validHost(host)) {
      return _fail(
        'endpoint.host_form',
        'Endpoint host must be an IP address or a valid hostname.',
      );
    }
    return Ok(WgEndpoint(host, port));
  }

  static Result<int> _parsePort(String raw) {
    final port = int.tryParse(raw.trim());
    if (port == null || port < minPort || port > maxPort) {
      return Err(
        AppError(
          group: ErrorGroup.validation,
          code: 'endpoint.port',
          message: 'Endpoint port must be between 1 and 65535.',
        ),
      );
    }
    return Ok(port);
  }

  static bool _validHost(String host) {
    if (host.contains(':') && RegExp(r'^[0-9A-Fa-f:]+$').hasMatch(host)) {
      return true;
    }
    final v4 = RegExp(
      r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$',
    ).firstMatch(host);
    if (v4 != null) {
      return v4
          .groups([1, 2, 3, 4])
          .every((g) => (int.tryParse(g!) ?? 999) <= 255);
    }
    final dns = RegExp(
      r'^(?=.{1,253}$)([A-Za-z0-9_-]{1,63}\.)+[A-Za-z]{2,63}$',
    );
    return dns.hasMatch(host);
  }

  static Result<WgEndpoint> _fail(String code, String message) =>
      Err(AppError(group: ErrorGroup.validation, code: code, message: message));

  String get display => host.contains(':') ? '[$host]:$port' : '$host:$port';

  @override
  String toString() => display;

  @override
  bool operator ==(Object other) =>
      other is WgEndpoint && other.host == host && other.port == port;

  @override
  int get hashCode => Object.hash(host, port);
}
