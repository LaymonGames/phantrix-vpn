import '../core/result.dart';



import '../model/vpn_server.dart';

/// The on-disk server cache.
///
/// Deliberately tolerant: a corrupt file is discarded, never fatal, because a
/// damaged cache must not stop the app from working. Schema is versioned so a
/// future release can migrate or discard.
abstract class DirectoryCache {
	const DirectoryCache();

	/// Reads the cached list. Returns null when absent or unreadable.
	Result<CachedDirectory> read();

	/// Writes the list atomically.
	void write(List<VpnServer> servers, DateTime fetchedAt);

	/// Drops the cache.
	void clear();
}

/// A persisted directory snapshot.
class CachedDirectory {
	const CachedDirectory(this.servers, this.fetchedAt);

	final List<VpnServer> servers;
	final DateTime fetchedAt;
}
