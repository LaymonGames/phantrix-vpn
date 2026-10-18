import 'fingerprint.dart';

/// The single place where secrets are removed before anything leaves the
/// process as log text.
///
/// Rules (see SECURITY.md):
///  * WireGuard keys, OpenVPN inline blocks and credential assignments are
///    replaced with a short, non-reversible marker.
///  * The marker is derived from a truncated FNV-1a digest so that two
///    occurrences of the same value can still be correlated during support
///    without revealing the value.
///  * Full URLs are collapsed to `scheme://host` because the path and query
///    can leak DNS identity.
///  * IPv6 addresses are truncated to their /48 prefix for the same reason.
class Redactor {
  Redactor._();

  static const String stableMarker = '[redacted]';

  static final RegExp _wgKey = RegExp(r'(?<![A-Za-z0-9+/])[A-Za-z0-9+/]{43}=');

  static final RegExp _pem = RegExp(
    r'-----BEGIN [^-]*-----.*?-----END [^-]*-----',
    dotAll: true,
  );

  static final RegExp _credential = RegExp(
    // Group 1 is the key name and group 2 the value. The replacement keeps
    // the key — "which secret is this" is useful in a support log — and
    // drops the value, which is the secret itself. Getting the groups the
    // wrong way round here would print the secret next to the marker that
    // claims it was removed, so the test below asserts absence, not just
    // the marker's presence.
    //
    // Case-insensitivity comes from `caseSensitive: false`, not from a
    // scoped `(?i:...)` flag. The scoped form misbehaves when the
    // alternation's first branch shares a prefix with a later one —
    // `presharedkey|password` silently fails to match `PresharedKey` —
    // which meant preshared keys were never redacted at all. A redactor
    // whose misses are silent is worse than none, because it is trusted.
    r'\b(auth-user-pass|password|passwd|pass|secret|token|presharedkey|privatekey|psk|username)[ \t]*[:=][ \t]*([^\s,;]+)',
    caseSensitive: false,
  );

  static final RegExp _url = RegExp(r'\b(https?)://([^/\s?]+)\S*');

  static final RegExp _ipv6 = RegExp(r'[0-9A-Fa-f:]{2,}:[0-9A-Fa-f:]{10,}');

  /// Returns [input] with every recognised secret replaced.
  static String redact(Object? input) {
    if (input == null) {
      return 'null';
    }
    var text = input.toString();
    text = _replaceAll(text, _pem, (_) => stableMarker);
    text = _replaceAll(text, _wgKey, fingerprint);
    // Runs after the WireGuard rule, so a value that is already a
    // `[redacted-…]` fingerprint marker must be left alone: without the
    // guard the credential rule would treat the marker itself as a secret
    // value and replace it with a bare `[redacted]`, destroying the
    // cross-line correlation the fingerprint exists to provide.
    text = _replaceAll(
      text,
      _credential,
      (m) => m.group(2)!.startsWith('[redacted')
          ? m.group(0)!
          : '${m.group(1)}: $stableMarker',
    );
    text = _replaceAll(text, _url, (m) => '${m.group(1)}://${m.group(2)}/…');
    text = _replaceAll(text, _ipv6, (m) {
      final groups = m.group(0)!.split(':');
      if (groups.length < 4) {
        return m.group(0)!;
      }
      return '${groups.take(4).join(':')}…/48';
    });
    return text;
  }

  /// A short, non-reversible identifier for a secret. Safe to print.
  static String fingerprint(Object? input) {
    if (input == null) {
      return stableMarker;
    }
    return '[redacted-${fingerprintHex(input.toString())}]';
  }

  static String _replaceAll(
    String text,
    RegExp pattern,
    String Function(Match) replace,
  ) {
    final buffer = StringBuffer();
    var cursor = 0;
    for (final match in pattern.allMatches(text)) {
      if (match.start < cursor) {
        continue;
      }
      buffer.write(text.substring(cursor, match.start));
      buffer.write(replace(match));
      cursor = match.end;
    }
    buffer.write(text.substring(cursor));
    return buffer.toString();
  }

  static String redactWireGuardConfig(Object? config) => redact(config);

  static String redactOpenVpnConfig(Object? config) => redact(config);
}
