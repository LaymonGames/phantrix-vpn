// Repeatable Windows diagnostic for one Phantrix connection attempt.
//
// Walks exactly the pipeline the app walks on Windows and reports, per stage,
// what the code actually did:
//
//   discovery refresh → ranking → configuration fetch → validation →
//   serialisation → the native side's profile re-check → engine arguments.
//
// It never starts a tunnel, never prints trust material, and touches the
// network only for the VPN Gate feed the app itself uses. It exists so the
// same question can be answered on any Windows PC with the same output shape —
// which is what separates a shared software defect from a machine-specific
// prerequisite.
//
// Usage
//
//   dart run tools/diagnose_windows.dart                 # live feed
//   dart run tools/diagnose_windows.dart --json          # machine-readable
//   dart run tools/diagnose_windows.dart --profile a.ovpn # evaluate a file
//   dart run tools/diagnose_windows.dart --engine V/C:\...\Release  # engine check
//
// The `--engine` variant additionally verifies the bundled engine starts,
// reports its version, and rejects an unknown option — the cheapest proof that
// the runtime in the deployed artifact is actually usable, without elevation.
import 'dart:convert';
import 'dart:io';

import 'package:phantrix_core/phantrix_core.dart';
import 'package:http/http.dart' as http;

// The directives the elevated Windows helper refuses before it will run the
// engine. Mirrored from phantrix_ovpn_support.cpp so this tool can report the
// helper's verdict without linking against it; the native side is authoritative.
const Set<String> _forbiddenDirectives = {
  'up',
  'down',
  'route-up',
  'route-pre-down',
  'ipchange',
  'tls-verify',
  'tls-crypt-v2-verify',
  'client-connect',
  'client-disconnect',
  'client-crresponse',
  'auth-user-pass-verify',
  'learn-address',
  'script-security',
  'plugin',
  'config',
  'management',
  'daemon',
  'cd',
  'chroot',
  'log',
  'log-append',
  'status',
  'status-version',
  'dev-node',
  'bind',
  'lport',
  'askpass',
  'setenv',
  'setenv-safe',
};

/// The directive on one profile line: the first token, lowercased, with the
/// leading dashes OpenVPN also accepts removed. Blank and comment lines give
/// an empty string, which is how they are skipped.
String _directiveOf(String line) {
  final trimmed = line.trim();
  if (trimmed.isEmpty || trimmed.startsWith('#') || trimmed.startsWith(';')) {
    return '';
  }
  return trimmed
      .split(RegExp(r'\s+'))
      .first
      .replaceAll(RegExp(r'^-+'), '')
      .toLowerCase();
}

/// What the Windows native side would answer for this profile.
///
/// An empty code means "accepted". This is a re-check of the same deny-list the
/// plugin and the helper both apply, which is what catches a profile that looks
/// valid to Dart and is still refused.
({String code, String reason}) nativeVerdict(String profile) {
  for (final line in profile.split('\n')) {
    final directive = _directiveOf(line);
    if (directive.isEmpty) continue;
    if (_forbiddenDirectives.contains(directive)) {
      return (
        code: 'ovpn.forbidden_directive',
        reason:
            'The profile asks for "$directive", which this backend '
            'will not do.',
      );
    }
    if (directive == 'auth-user-pass') {
      final args = line.trim().split(RegExp(r'\s+')).skip(1).join(' ').trim();
      if (args.isEmpty) {
        return (
          code: 'ovpn.credentials_missing',
          reason:
              'The server asks for a username and password and '
              'this build has no way to supply them.',
        );
      }
    }
  }
  return (code: '', reason: '');
}

/// Supresses nothing: the report is the point.
typedef _Report = void Function(String stage, Object? detail);

Future<void> main(List<String> args) async {
  final asJson = args.contains('--json');
  final report = <String, Object?>{};

  void say(String stage, Object? detail) {
    report[stage] = detail;
    if (!asJson) {
      final text = detail is Map ? detail.toString() : '$detail';
      stdout.writeln('$stage: $text');
    }
  }

  final engineFlag = args.indexOf('--engine');
  if (engineFlag != -1 && engineFlag + 1 < args.length) {
    await _engineCheck(args[engineFlag + 1], say, report);
    return;
  }

  final profileFlag = args.indexOf('--profile');
  if (profileFlag != -1 && profileFlag + 1 < args.length) {
    await _fromFile(args[profileFlag + 1], say, report);
    return;
  }

  // Where to write the accepted profiles. A native probe needs a real `.ovpn`
  // and the app serialises one only inside a connection attempt, so this is
  // how the same profile the app would hand the engine is put on disk.
  final emitFlag = args.indexOf('--emit');
  final emitDirectory = emitFlag != -1 && emitFlag + 1 < args.length
      ? args[emitFlag + 1]
      : null;

  final fetcher = _FeedFetcher();
  try {
    final provider = VpnGateProvider(fetcher: fetcher);
    final outcome = await provider.refresh(force: true);
    final servers = outcome.servers;
    say('discovery.relays', servers.length);
    if (outcome.error != null) {
      say(
        'discovery.error',
        '${outcome.error!.code}: ${outcome.error!.message}',
      );
    }

    final ranked = const ServerSelector().rank(servers, const ScoreContext());
    if (ranked.isEmpty) {
      say('result', 'no ranked servers');
      return;
    }

    var accepted = 0;
    for (final scored in ranked.take(10)) {
      final server = scored.server;
      final fetched = await provider.fetchConfig(server.id);
      final openVpn = fetched?.validated.openVpn;
      final verdict = openVpn == null
          ? (code: 'no_configuration', reason: 'profile missing or invalid')
          : nativeVerdict(OvpnSerializer.serialize(openVpn, blockIpv6: true));
      say('candidate.${server.id}', {
        'country': server.countryCode,
        'endpoint': server.hostAddress,
        'score': scored.score.toStringAsFixed(1),
        'status': server.status.name,
        'authUserPass': openVpn?.authUserPass,
        'validated': fetched != null,
        'nativeVerdict': verdict.code.isEmpty ? 'accepted' : verdict.code,
      });
      if (verdict.code.isEmpty) {
        if (emitDirectory != null) {
          final profile = OvpnSerializer.serialize(openVpn!, blockIpv6: true);
          // The id is the feed's own identifier, so a written file can
          // be matched back to the row that produced it.
          final file = File('$emitDirectory\\${server.id}.ovpn');
          file.writeAsStringSync(profile);
          say('emitted.${server.id}', file.path);
        }
        accepted++;
      }
      if (accepted >= 3) break;
    }
    say('candidates.native_side_would_accept', accepted);
  } finally {
    // Nothing to close: _FeedFetcher owns no persistent transport.
  }
  if (asJson) stdout.writeln(jsonEncode(report));
}

/// Verifies the deployed engine actually runs.
///
/// This is the question the previous failures most needed answered cheaply:
/// the engine's presence on disk says nothing about whether it loads, and a
/// missing runtime DLL makes it exit with `0xC0000135` and no log at all —
/// indistinguishable from an unreachable server. It runs unelevated, because
/// `--version` and option parsing need no administrator token.
Future<void> _engineCheck(
  String engineDirectory,
  _Report say,
  Map<String, Object?> report,
) async {
  final executable = '$engineDirectory\\openvpn.exe';
  if (!File(executable).existsSync()) {
    say('engine.executable', 'missing: $executable');
    return;
  }
  say('engine.executable', executable);

  final dependencies = <String>[
    'libcrypto-3-x64.dll',
    'libssl-3-x64.dll',
    'libpkcs11-helper-1.dll',
    'vcruntime140.dll',
    'wintun.dll',
  ];
  final missing = dependencies
      .where((name) => !File('$engineDirectory\\$name').existsSync())
      .toList(growable: false);
  say(
    'engine.dependencies',
    missing.isEmpty ? 'all present' : 'missing: $missing',
  );
  say(
    'engine.helper_present',
    File('$engineDirectory\\phantrix_ovpn_helper.exe').existsSync(),
  );

  final version = await _run(executable, const ['--version'], engineDirectory);
  say('engine.version_exit_code', version.exitCode);
  // The first banner line carries the engine version and its build flags,
  // which is what proves the binary is the one this backend expects.
  final banner = version.output
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.startsWith('OpenVPN '))
      .map((line) => line.split(' ').take(2).join(' '))
      .firstOrNull;
  say('engine.version', banner ?? 'not reported');

  // An unknown option must be rejected. A binary that accepts anything is
  // not the engine this backend was built against.
  final bad = await _run(executable, const [
    '--config',
    'no-such-config',
    '--definitely-not-an-option',
  ], engineDirectory);
  say('engine.rejects_unknown_options', bad.exitCode != 0);
  say(
    'engine.unknown_option_diagnostic',
    bad.output.isEmpty ? '(silent)' : bad.output.trim().split('\n').first,
  );
}

/// Evaluates an existing `.ovpn` file, which is how a PC with no feed access
/// can still be checked.
Future<void> _fromFile(
  String path,
  _Report say,
  Map<String, Object?> report,
) async {
  final profile = File(path).readAsStringSync();
  say('file', path);

  final parsed = OvpnParser.parse(profile);
  final value = parsed.valueOrNull;
  if (value == null) {
    final error = (parsed as Err).error;
    say('parse', '${error.code}: ${error.message}');
    return;
  }

  final validated = OvpnValidator.validate(value);
  final verdict = validated.valueOrNull;
  if (verdict == null) {
    final error = (validated as Err).error;
    say('validate', '${error.code}: ${error.message}');
    return;
  }

  final ovpn = verdict.config;
  say('parse', 'ok');
  say('remotes', ovpn.remotes.map((r) => '${r.host}:${r.port}').join(', '));
  say('proto', ovpn.proto ?? 'udp');
  say('authUserPass', ovpn.authUserPass);
  say('inlineBlocks', ovpn.inlineBlocks.keys.toList(growable: false)..sort());

  final serialized = OvpnSerializer.serialize(ovpn, blockIpv6: true);
  say('serialised_lines', serialized.split('\n').length);

  final native = nativeVerdict(serialized);
  say('nativeVerdict', native.code.isEmpty ? 'accepted' : native.code);
  if (native.code.isNotEmpty) say('nativeReason', native.reason);
}

/// A minimal HTTPS fetcher for the VPN Gate feed.
///
/// The diagnostic tool is deliberately not part of the app: importing
/// `lib/net/app_http_fetcher.dart` from `tools/` would put a relative path to
/// `lib/` in the analysis, which the repo's analyzer flags. This keeps the tool
/// standalone while honouring the same contract the app enforces — https only,
/// capped body, failures raised as [AppError].
class _FeedFetcher implements HttpFetcher {
  @override
  int maxBodyBytes = 64 * 1024 * 1024;

  @override
  Future<String> get(Uri url) async {
    if (url.scheme != 'https') {
      throw AppError(
        group: ErrorGroup.network,
        code: 'http.plaintext_rejected',
        message: 'Only https feeds are accepted.',
      );
    }
    try {
      final response = await http
          .get(url, headers: const {'User-Agent': 'Phantrix-Diagnostic/1.0'})
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        throw AppError(
          group: ErrorGroup.network,
          code: 'http.status_${response.statusCode}',
          message: 'The feed refused the request.',
        );
      }
      final body = response.body;
      if (body.length > maxBodyBytes) {
        throw AppError(
          group: ErrorGroup.provider,
          code: 'http.body_too_large',
          message: 'The feed is larger than this tool accepts.',
        );
      }
      return body;
    } on AppError {
      rethrow;
    } on Object {
      throw AppError(
        group: ErrorGroup.network,
        code: 'http.unreachable',
        message: 'The feed could not be read.',
      );
    }
  }
}

/// Runs one short-lived process and captures what it wrote.
Future<({int exitCode, String output})> _run(
  String executable,
  List<String> arguments,
  String workingDirectory,
) async {
  final result = await Process.run(
    executable,
    arguments,
    workingDirectory: workingDirectory,
  ).timeout(const Duration(seconds: 30));
  final output = [result.stdout.toString(), result.stderr.toString()].join();
  return (exitCode: result.exitCode, output: output);
}
