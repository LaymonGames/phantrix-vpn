import 'dart:convert';
import 'dart:io';

import 'package:phantrix_core/phantrix_core.dart';

/// App-private persistence for the public VPN Gate feed's client profiles.
///
/// This is kept separate from the visible server-directory cache. The file is
/// versioned, size-limited, and only read by the provider, which re-validates a
/// profile before passing it to the VPN engine. It can contain the public feed's
/// shared client keys, but never user-supplied configuration or private keys.
class FileVpnGateProfileCache extends VpnGateProfileCache {
  FileVpnGateProfileCache(this.file);

  factory FileVpnGateProfileCache.inDirectory(String directory) =>
      FileVpnGateProfileCache(
        File('$directory${Platform.pathSeparator}vpn-gate-profiles-cache.json'),
      );

  static const int _schemaVersion = 1;
  static const int _maxProfiles = 2000;
  static const int _maxBytes = 48 * 1024 * 1024;
  static const int _maxEncodedProfileLength = 1024 * 1024;

  final File file;

  @override
  Map<String, String> read() {
    try {
      if (!file.existsSync() || file.lengthSync() > _maxBytes) {
        return const {};
      }
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map || decoded['version'] != _schemaVersion) {
        return const {};
      }
      final rawProfiles = decoded['profiles'];
      if (rawProfiles is! Map || rawProfiles.length > _maxProfiles) {
        return const {};
      }

      final profiles = <String, String>{};
      for (final entry in rawProfiles.entries) {
        if (entry.key is! String ||
            (entry.key as String).isEmpty ||
            entry.value is! String ||
            (entry.value as String).isEmpty ||
            (entry.value as String).length > _maxEncodedProfileLength) {
          return const {};
        }
        profiles[entry.key as String] = entry.value as String;
      }
      return Map.unmodifiable(profiles);
    } on Object {
      return const {};
    }
  }

  @override
  void write(Map<String, String> profiles) {
    if (profiles.isEmpty) {
      return;
    }
    try {
      final selected = <String, String>{};
      for (final entry in profiles.entries) {
        if (entry.key.isEmpty ||
            entry.key.length > 253 ||
            entry.value.isEmpty ||
            entry.value.length > _maxEncodedProfileLength) {
          continue;
        }
        selected[entry.key] = entry.value;
        if (selected.length >= _maxProfiles) {
          break;
        }
      }
      if (selected.isEmpty) {
        return;
      }
      final payload = jsonEncode({
        'version': _schemaVersion,
        'savedAt': DateTime.now().toUtc().toIso8601String(),
        'profiles': selected,
      });
      if (utf8.encode(payload).length > _maxBytes) {
        return;
      }

      file.parent.createSync(recursive: true);
      final temporary = File('${file.path}.tmp');
      temporary.writeAsStringSync(payload, flush: true);
      temporary.renameSync(file.path);
    } on Object {
      // Persistence is opportunistic. A failed cache write must not turn a
      // successful server refresh into a failed discovery operation.
      try {
        final temporary = File('${file.path}.tmp');
        if (temporary.existsSync()) {
          temporary.deleteSync();
        }
      } on Object {
        // Nothing else can be done safely here.
      }
    }
  }

  @override
  void clear() {
    for (final path in [file.path, '${file.path}.tmp']) {
      try {
        final target = File(path);
        if (target.existsSync()) {
          target.deleteSync();
        }
      } on Object {
        // Cache cleanup is best effort.
      }
    }
  }
}
