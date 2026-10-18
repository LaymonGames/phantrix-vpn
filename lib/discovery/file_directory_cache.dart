import 'dart:convert';
import 'dart:io';

import 'package:phantrix_core/phantrix_core.dart';

import 'file_vpn_gate_profile_cache.dart';

part 'file_directory_cache_helpers.dart';

/// Small, versioned cache of public server metadata.
///
/// This file stores directory metadata only. Public VPN Gate profiles are
/// stored separately by [FileVpnGateProfileCache], allowing an explicit
/// connection attempt during a feed outage without mixing profile material
/// into the visible directory snapshot.
class FileDirectoryCache extends DirectoryCache {
  FileDirectoryCache(this.file);

  factory FileDirectoryCache.inDirectory(String directory) =>
      FileDirectoryCache(
        File('$directory${Platform.pathSeparator}directory-cache.json'),
      );

  static const int _schemaVersion = 1;
  static const int _maxServers = 2000;
  static const int _maxBytes = 4 * 1024 * 1024;

  final File file;

  @override
  Result<CachedDirectory> read() {
    try {
      if (!file.existsSync()) {
        return const Err(
          AppError(
            group: ErrorGroup.storage,
            code: 'directory_cache.missing',
            message: 'No saved server directory is available.',
          ),
        );
      }
      if (file.lengthSync() > _maxBytes) {
        return _corrupt();
      }
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map || decoded['version'] != _schemaVersion) {
        return _corrupt();
      }
      final fetchedAtRaw = decoded['fetchedAt'];
      final fetchedAt = fetchedAtRaw is String
          ? DateTime.tryParse(fetchedAtRaw)
          : null;
      final rawServers = decoded['servers'];
      if (fetchedAt == null ||
          rawServers is! List ||
          rawServers.isEmpty ||
          rawServers.length > _maxServers) {
        return _corrupt();
      }
      final servers = <VpnServer>[];
      for (final raw in rawServers) {
        if (raw is! Map) {
          return _corrupt();
        }
        servers.add(_decodeServer(raw));
      }
      return Ok(
        CachedDirectory(List.unmodifiable(servers), fetchedAt.toLocal()),
      );
    } on Object {
      return _corrupt();
    }
  }

  @override
  void write(List<VpnServer> servers, DateTime fetchedAt) {
    if (servers.isEmpty) {
      return;
    }
    try {
      final selected = servers.length > _maxServers
          ? servers.sublist(servers.length - _maxServers)
          : servers;
      final payload = jsonEncode({
        'version': _schemaVersion,
        'fetchedAt': fetchedAt.toUtc().toIso8601String(),
        'servers': selected.map(_encodeServer).toList(growable: false),
      });
      if (utf8.encode(payload).length > _maxBytes) {
        return;
      }
      file.parent.createSync(recursive: true);
      final temporary = File('${file.path}.tmp');
      temporary.writeAsStringSync(payload, flush: true);
      temporary.renameSync(file.path);
    } on FileSystemException {
      // Cache writes are opportunistic. The fresh in-memory list remains
      // usable even on a read-only disk or if the device is low on space.
      try {
        final temporary = File('${file.path}.tmp');
        if (temporary.existsSync()) {
          temporary.deleteSync();
        }
      } on FileSystemException {
        // Nothing else can be done safely here.
      }
    }
  }

  @override
  void clear() {
    try {
      if (file.existsSync()) {
        file.deleteSync();
      }
      final temporary = File('${file.path}.tmp');
      if (temporary.existsSync()) {
        temporary.deleteSync();
      }
    } on FileSystemException {
      // Clearing optional metadata must not stop the application.
    }
  }
}
