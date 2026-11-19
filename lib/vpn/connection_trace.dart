import 'dart:io';

/// Append-only, size-capped log of connection attempts, kept beside the
/// engine logs (`<app data>/logs/connection.log`).
///
/// The engine logs say what OpenVPN saw; this says what the app decided:
/// which server it picked, how long it gave it, and why it gave up. Without
/// it a failed connection can only be guessed at after the fact.
///
/// Holds no secrets: server addresses, countries, failure codes and the
/// user-facing failure message only. Every write is best effort.
class ConnectionTrace {
  ConnectionTrace._();

  static File? _file;

  /// Capped so a long-running install never grows it without bound.
  static const int _maxBytes = 512 * 1024;

  /// Points the trace at [appDataDirectory]. Without this call (tests, web)
  /// every [log] is a no-op.
  static void configure(String? appDataDirectory) {
    if (appDataDirectory == null || appDataDirectory.isEmpty) {
      _file = null;
      return;
    }
    _file = File(
      '$appDataDirectory${Platform.pathSeparator}logs'
      '${Platform.pathSeparator}connection.log',
    );
  }

  static void log(String line) {
    final file = _file;
    if (file == null) {
      return;
    }
    try {
      file.parent.createSync(recursive: true);
      if (file.existsSync() && file.lengthSync() > _maxBytes) {
        final old = File('${file.path}.1');
        if (old.existsSync()) {
          old.deleteSync();
        }
        file.renameSync(old.path);
      }
      file.writeAsStringSync(
        '${DateTime.now().toIso8601String()} $line\n',
        mode: FileMode.append,
        flush: true,
      );
    } on Object {
      // Diagnostics must never break a connection attempt.
    }
  }
}
