import '../core/app_error.dart';
import '../core/result.dart';
import '../model/vpn_server.dart';
import 'directory_cache.dart';

/// A [DirectoryCache] that lives only for the process.
///
/// This is the honest default: it works, it never fails, and it does exactly
/// what its name says. It does **not** survive an app restart, and it must not
/// be described as an offline cache. Persisting the directory to disk needs a
/// storage plugin and a schema migration; until that exists, claiming the
/// app works offline from a saved list would be a lie.
///
/// A future file-backed implementation belongs here too, behind the same
/// [DirectoryCache] interface, so no caller changes.
class MemoryDirectoryCache extends DirectoryCache {
  MemoryDirectoryCache({this.maxEntries = 2000});

  /// Upper bound on retained servers.
  ///
  /// A hostile or broken feed could otherwise grow memory without limit.
  /// When the list is trimmed, the oldest entries go first: a fresh server
  /// is more useful than a stale one.
  final int maxEntries;

  List<VpnServer>? _servers;
  DateTime? _fetchedAt;

  bool get isEmpty => _servers == null || _servers!.isEmpty;

  @override
  Result<CachedDirectory> read() {
    final servers = _servers;
    final at = _fetchedAt;
    if (servers == null || at == null || servers.isEmpty) {
      return const Err(
        AppError(
          group: ErrorGroup.storage,
          code: 'cache.empty',
          message: 'No server list has been cached in this session.',
        ),
      );
    }
    return Ok(CachedDirectory(List.unmodifiable(servers), at));
  }

  @override
  void write(List<VpnServer> servers, DateTime fetchedAt) {
    if (servers.isEmpty) {
      // An empty successful refresh is not a cacheable state; keeping the
      // previous list is more useful than replacing it with nothing.
      return;
    }
    final trimmed = servers.length > maxEntries
        ? servers.sublist(servers.length - maxEntries)
        : servers;
    _servers = List.unmodifiable(trimmed);
    _fetchedAt = fetchedAt;
  }

  @override
  void clear() {
    _servers = null;
    _fetchedAt = null;
  }
}
