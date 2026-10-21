import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// A key/value store the app keeps its own state in.
///
/// The interface exists so that persistence is testable and so that a
/// platform with no writable storage can still run. There is deliberately no
/// "read from a global" and no singleton: the caller decides where the store
/// comes from, which is what lets a widget test supply one without a platform
/// channel and without touching the real user's files.
abstract class AppStore {
  /// Reads [key], or null when it has never been written.
  Future<String?> read(String key);

  /// Writes [key]. Overwrites any previous value.
  Future<void> write(String key, String value);

  /// Removes [key]. Removing an absent key is not an error.
  Future<void> delete(String key);

  /// Every key currently held, in insertion order where that is meaningful.
  Future<Set<String>> keys();
}

/// A store that keeps nothing.
///
/// Used on the web, where nothing may be persisted, and in tests that are
/// about behaviour rather than persistence. It behaves correctly — reads
/// return null and writes are dropped — so nothing above it has to branch on
/// "is this a real store".
class MemoryAppStore implements AppStore {
  MemoryAppStore([Map<String, String>? seed]) : _values = {...?seed};

  final Map<String, String> _values;

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;

  @override
  Future<void> delete(String key) async => _values.remove(key);

  @override
  Future<Set<String>> keys() async => _values.keys.toSet();

  @visibleForTesting
  Map<String, String> get snapshot => Map.unmodifiable(_values);
}

/// A store backed by one JSON file.
///
/// ## Why a single file
///
/// Settings, the selected server and the cached directories are small, and
/// they are changed together — the app reads all of them at start-up before it
/// draws anything. Splitting them across files would mean a partially-written
/// set that the app has to reconcile, and every reconciliation path is a way
/// for the UI to show something the disk does not say.
///
/// ## Why the write is atomic
///
/// The file is written to a temporary sibling and renamed over the original.
/// A rename within one directory is atomic on POSIX and on Windows, so a
/// crash, a battery pull or a full disk during the write leaves the previous
/// file intact rather than a half-written one. Writing in place would leave a
/// truncated file that fails to parse on next launch, and the user would lose
/// their settings to a bad shutdown.
///
/// ## Permissions
///
/// On POSIX the file is created 0600 and the directory 0700, because the file
/// holds the user's settings, favourites and history. The mode is applied
/// explicitly after creation rather than relied on from the process umask,
/// which a user or a distribution may have set to something permissive.
class FileAppStore implements AppStore {
  FileAppStore(this.file);

  /// Creates the store in [directory], which is the platform's private
  /// application directory.
  factory FileAppStore.inDirectory(
    String directory, {
    required String fileName,
  }) {
    return FileAppStore(File('$directory${Platform.pathSeparator}$fileName'));
  }

  final File file;

  Map<String, String>? _cache;
  Future<void>? _pendingWrite;

  Map<String, String> _loadSync() {
    if (_cache != null) {
      return _cache!;
    }
    if (!file.existsSync()) {
      return _cache = <String, String>{};
    }
    String raw;
    try {
      raw = file.readAsStringSync();
    } on FileSystemException {
      // Unreadable is treated as empty: the app must still start, and a
      // corrupt file must not become a permanent launch failure. The next
      // write replaces it.
      return _cache = <String, String>{};
    }
    if (raw.trim().isEmpty) {
      return _cache = <String, String>{};
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return _cache = <String, String>{};
      }
      return _cache = decoded.map(
        (key, value) => MapEntry(key.toString(), value.toString()),
      );
    } on FormatException {
      return _cache = <String, String>{};
    }
  }

  Future<void> _persist() async {
    final directory = file.parent;
    if (!directory.existsSync()) {
      directory.createSync(recursive: true);
      _restrict(directory, isDirectory: true);
    }
    final temporary = File('${file.path}.tmp');
    try {
      temporary.writeAsStringSync(
        jsonEncode(_cache ?? const <String, String>{}),
      );
      _restrict(temporary, isDirectory: false);
      // rename over the original: atomic within one directory. The mode
      // travels with the inode, so the file that appears at the final name
      // already carries the restriction applied above.
      temporary.renameSync(file.path);
    } finally {
      if (temporary.existsSync()) {
        temporary.deleteSync();
      }
    }
  }

  /// Applies owner-only permissions, where the platform has them.
  ///
  /// Files get `0600` and directories `0700`: the distinction matters,
  /// because an owner-executable bit on a file is meaningless for a JSON
  /// store and a group-readable bit on either would expose a private key.
  /// The mode is passed explicitly rather than inherited from the process
  /// umask, which a user or a distribution may have set permissively — and
  /// a umask can only ever remove bits, never add them, so applying the
  /// mode directly cannot make anything more permissive than it was.
  ///
  /// Takes a [FileSystemEntity] because both the directory and the file need
  /// it, and a private key is only as private as the directory holding it.
  ///
  /// Skipped on Windows and Android, for different reasons. Windows has no
  /// POSIX mode bits; the ACL is set by the native side when it creates the
  /// directory (see `dataDirectory` in the Windows backend), because only
  /// native code can express a DACL. On Android the `chmod` binary is not
  /// reliably present in an app's execution environment, so spawning it
  /// would silently do nothing on exactly the platform where silence is
  /// dangerous — and it is unnecessary there, because `filesDir` is
  /// UID-private by the kernel, backups are disabled, and nothing is ever
  /// written to shared storage. Spawning a process that cannot work, to
  /// satisfy a check nobody can observe, would be security theater.
  void _restrict(FileSystemEntity target, {required bool isDirectory}) {
    if (Platform.isWindows || Platform.isAndroid) {
      return;
    }
    try {
      Process.runSync('chmod', [isDirectory ? '700' : '600', target.path]);
    } on ProcessException {
      // If chmod cannot run the file still lands inside a directory the
      // user owns. Refusing to save at all would be worse than a file
      // that is slightly more permissive than intended.
    }
  }

  @override
  Future<String?> read(String key) async => _loadSync()[key];

  @override
  Future<void> write(String key, String value) async {
    _loadSync()[key] = value;
    await _schedulePersist();
  }

  @override
  Future<void> delete(String key) async {
    if (_loadSync().remove(key) != null) {
      await _schedulePersist();
    }
  }

  @override
  Future<Set<String>> keys() async => _loadSync().keys.toSet();

  /// Serialises concurrent writes so two rapid changes cannot interleave
  /// and leave the later one on disk without the earlier.
  Future<void> _schedulePersist() {
    final previous = _pendingWrite;
    _pendingWrite = previous == null
        ? _persist()
        : previous.catchError((Object _) {}).then((_) => _persist());
    return _pendingWrite!;
  }
}

/// Chooses the store for the running platform.
///
/// Prefers a real file when the platform reports a private directory, and
/// silently falls back to memory when it does not. The fallback is silent on
/// purpose: on the web, "settings are remembered for this session only" is the
/// expected behaviour of every web application, and reporting an error would
/// make a working app look broken.
Future<AppStore> openDefaultStore(
  String? platformDirectory, {
  String fileName = 'phantrix-store.json',
}) async {
  if (platformDirectory == null || platformDirectory.isEmpty) {
    return MemoryAppStore();
  }
  return FileAppStore.inDirectory(platformDirectory, fileName: fileName);
}
