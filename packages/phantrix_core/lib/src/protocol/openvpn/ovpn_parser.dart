import '../../core/app_error.dart';
import '../../core/result.dart';
import 'ovpn_config.dart';

/// Parses OpenVPN configuration files, including inline PEM blocks.
///
/// Ordering rules that matter for correctness:
///  * An inline block starts with `<tag>` at the beginning of a line and ends
///    with `</tag>`. Everything between is preserved verbatim because OpenVPN
///    allows arbitrary base64 wrapping.
///  * Whitespace inside a block is *not* collapsed.
///  * `remote` may appear several times; order is significant for failover.
class OvpnParser {
  const OvpnParser._();
  static Result<OvpnConfig> parse(String text) {
    final normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final lines = normalized.split('\n');
    final comments = <String>[];
    final directives = <OvpnDirective>[];
    final inline = <String, String>{};
    final unknown = <String, String>{};
    String? openTag;
    final body = StringBuffer();
    for (var i = 0; i < lines.length; i++) {
      final lineNumber = i + 1;
      var line = lines[i];
      final trimmed = line.trim();
      if (openTag != null) {
        if (trimmed == '</$openTag>') {
          inline[openTag.toLowerCase()] = body.toString();
          openTag = null;
          body.clear();
        } else {
          body.writeln(line);
        }
        continue;
      }
      if (trimmed.isEmpty) {
        continue;
      }
      final closeMatch = RegExp(r'^</([A-Za-z0-9_-]+)>').firstMatch(trimmed);
      if (closeMatch != null) {
        return Err(
          AppError(
            group: ErrorGroup.parse,
            code: 'ovpn.unbalanced_block',
            message:
                'Found "</${closeMatch.group(1)}>" without a matching opening tag.',
            detail: {'line': lineNumber},
          ),
        );
      }
      final openMatch = RegExp(r'^<([A-Za-z0-9_-]+)>').firstMatch(trimmed);
      if (openMatch != null) {
        openTag = openMatch.group(1) ?? openTag;
        continue;
      }
      if (trimmed.startsWith('#') || trimmed.startsWith(';')) {
        comments.add(trimmed);
        continue;
      }
      final parts = trimmed.split(RegExp(r'\s+'));
      final key = parts.isEmpty ? '' : parts.first.toLowerCase();
      final value = parts.length > 1 ? parts.sublist(1).join(' ') : '';
      if (key.isEmpty) {
        continue;
      }
      directives.add(OvpnDirective(key, value, line: lineNumber));
      unknown[key] = value;
    }
    if (openTag != null) {
      return Err(
        AppError(
          group: ErrorGroup.parse,
          code: 'ovpn.unterminated_block',
          message:
              'The inline <$openTag> block is never closed with </$openTag>.',
        ),
      );
    }
    final config = _assemble(directives, inline, comments, unknown);
    return Ok(config);
  }

  static OvpnConfig _assemble(
    List<OvpnDirective> directives,
    Map<String, String> inline,
    List<String> comments,
    Map<String, String> unknown,
  ) {
    final remotes = <OvpnRemote>[];
    String? proto;
    String? dev;
    String? cipher;
    final dataCiphers = <String>[];
    String? dataCiphersFallback;
    String? auth;
    String? tlsVersionMin;
    String? tlsCertProfile;
    String? keyDirection;
    String? verifyX509Name;
    var authUserPass = false;
    String? authUserPassFile;
    String? caFile;
    String? certFile;
    String? keyFile;
    String? caPath;
    bool? pull;
    bool? redirectGateway;
    final dns = <String>[];
    var routeNopull = false;
    int? verbosity;
    // OpenVPN's default is 1194 for both TCP and UDP. A global port may
    // appear after a remote; malformed explicit ports must reach validation
    // as invalid rather than silently selecting another server port.
    final globalPort = unknown['rport'] ?? unknown['port'];
    final defaultPort = globalPort == null
        ? 1194
        : int.tryParse(globalPort) ?? -1;
    for (final directive in directives) {
      switch (directive.key) {
        case 'remote':
          final parts = directive.value.split(RegExp(r'\s+'));
          if (parts.isEmpty || parts.first.isEmpty) {
            continue;
          }
          final port = parts.length > 1
              ? int.tryParse(parts[1]) ?? -1
              : defaultPort;
          remotes.add(
            OvpnRemote(
              host: parts.first,
              port: port,
              proto: parts.length > 2 ? parts[2].toLowerCase() : null,
            ),
          );
        case 'proto':
          proto = directive.value.toLowerCase();
        case 'dev' || 'dev-type':
          dev ??= directive.value;
        case 'cipher':
          cipher = directive.value;
        case 'data-ciphers':
          for (final entry in directive.value.split(':')) {
            final value = entry.trim();
            if (value.isNotEmpty) {
              dataCiphers.add(value);
            }
          }
        case 'data-ciphers-fallback':
          dataCiphersFallback = directive.value;
        case 'auth':
          auth = directive.value;
        case 'tls-version-min':
          tlsVersionMin = directive.value;
        case 'tls-cert-profile':
          tlsCertProfile = directive.value;
        case 'key-direction':
          keyDirection = directive.value;
        case 'verify-x509-name':
          verifyX509Name = directive.value;
        case 'auth-user-pass':
          authUserPass = true;
          final value = directive.value.trim();
          authUserPassFile = value.isEmpty ? null : value;
        case 'ca':
          caFile = directive.value;
        case 'cert':
          certFile = directive.value;
        case 'key':
          keyFile = directive.value;
        case 'ca path':
          caPath = directive.value;
        case 'pull':
          pull =
              directive.value.isEmpty ||
              directive.value.toLowerCase() == 'true';
        case 'redirect-gateway':
          redirectGateway = true;
        case 'dhcp-option':
          if (directive.value.toLowerCase().startsWith('dns')) {
            final parts = directive.value.split(RegExp(r'\s+'));
            if (parts.length > 1) {
              dns.addAll(parts.sublist(1).where((p) => p.isNotEmpty));
            }
          }
        case 'route-nopull':
          routeNopull = true;
        case 'verb':
          verbosity = int.tryParse(directive.value);
        default:
          break;
      }
    }
    final inlineBlocks = <String, OvpnInlineBlock>{
      for (final entry in inline.entries)
        entry.key: OvpnInlineBlock(entry.key, entry.value.trim()),
    };
    return OvpnConfig(
      remotes: List.unmodifiable(remotes),
      proto: proto,
      dev: dev,
      cipher: cipher,
      dataCiphers: List.unmodifiable(dataCiphers),
      dataCiphersFallback: dataCiphersFallback,
      auth: auth,
      tlsVersionMin: tlsVersionMin,
      tlsCertProfile: tlsCertProfile,
      keyDirection: keyDirection,
      verifyX509Name: verifyX509Name,
      authUserPass: authUserPass,
      authUserPassFile: authUserPassFile,
      caFile: caFile,
      certFile: certFile,
      keyFile: keyFile,
      caPath: caPath,
      pull: pull,
      redirectGateway: redirectGateway,
      dhcpOptionDns: List.unmodifiable(dns),
      routeNopull: routeNopull,
      verbosity: verbosity,
      inlineBlocks: inlineBlocks,
      rawDirectives: {for (final d in directives) d.key: d.value},
      comments: List.unmodifiable(comments),
      unknownDirectives: unknown,
    );
  }
}
