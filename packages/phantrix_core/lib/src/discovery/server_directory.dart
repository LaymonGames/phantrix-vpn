import '../core/app_error.dart';



import '../model/vpn_server.dart';
import 'directory_cache.dart';
import 'server_merger.dart';

/// Why a refresh produced the servers it did.
///
/// The user must be able to tell the difference between "the directory is
/// broken" and "you are not connected to the internet", so this is a real
/// state, not a bool.
enum DirectoryState {
	/// Never refreshed successfully and no cache present.
	empty('No server list yet'),

	/// Fresh data was fetched.
	fresh('Server list is current'),

	/// Showing data older than the staleness threshold.
	stale('Server list is out of date'),

	/// Fresh data could not be fetched; the cache is being used.
	offlineUsingCache('Server list is cached (could not reach it)'),

	/// The cache is corrupt and was discarded.
	cacheCorrupt('Saved server list was damaged and was rebuilt');

	const DirectoryState(this.label);

	final String label;
}

/// Where a server came from, for provenance in the UI.
class ServerOrigin {
	const ServerOrigin({required this.providerId, required this.fetchedAt});

	final String providerId;
	final DateTime fetchedAt;
}

/// The current aggregate view over every provider.
///
/// Immutable snapshot: the UI renders this and nothing else, so a partially
/// updated server can never be shown.
class DirectorySnapshot {
	const DirectorySnapshot({
		required this.servers,
		required this.state,
		required this.byCountry,
		required this.lastFetchedAt,
		required this.providerErrors,
	});

	static const DirectorySnapshot empty = DirectorySnapshot(
		servers: [],
		state: DirectoryState.empty,
		byCountry: {},
		lastFetchedAt: null,
		providerErrors: {},
	);

	final List<VpnServer> servers;
	final DirectoryState state;

	/// Servers grouped by country code.
	final Map<String, List<VpnServer>> byCountry;

	final DateTime? lastFetchedAt;
	final Map<String, AppError> providerErrors;

	int get serverCount => servers.length;

	int get countryCount => byCountry.length;

	List<VpnServer> serversIn(String countryCode) =>
			byCountry[countryCode.toUpperCase()] ?? const [];

	bool get isEmpty => servers.isEmpty;

	int countFor(String countryCode) => serversIn(countryCode).length;
}

/// Combines provider output into one de-duplicated, ranked snapshot.
///
/// Responsibilities that must be in one place:
///  * de-duplicate the same endpoint offered by several providers;
///  * merge provider metadata (a lat measured by us wins over a published
///    number, a published number wins over nothing);
///  * keep provenance so the UI can attribute a server;
///  * expose provider failures without hiding them.
class ServerDirectory {
	ServerDirectory({
		required this.cache,
		Duration? staleAfter,
	}) : staleAfter = staleAfter ?? const Duration(minutes: 30);

	/// Cache used to survive a provider outage.
	final DirectoryCache cache;

	/// How long data may be served before it is considered stale.
	final Duration staleAfter;

	List<VpnServer> _servers = const [];
	DateTime? _fetchedAt;
	final Map<String, AppError> _providerErrors = {};

	List<VpnServer> get servers => List.unmodifiable(_servers);
	DateTime? get lastFetchedAt => _fetchedAt;
	Map<String, AppError> get providerErrors => Map.unmodifiable(_providerErrors);

	/// The state that describes the data currently held.
	DirectoryState get state {
		final at = _fetchedAt;
		if (_servers.isEmpty) {
			if (at == null) {
				return DirectoryState.empty;
			}
			return DirectoryState.cacheCorrupt;
		}
		if (at == null) {
			return DirectoryState.offlineUsingCache;
		}
		final age = DateTime.now().difference(at);
		return age > staleAfter ? DirectoryState.stale : DirectoryState.fresh;
	}

	/// Replaces the contents with a freshly merged set.
	void replaceAll(List<VpnServer> merged, DateTime fetchedAt) {
		_servers = List.unmodifiable(merged);
		_fetchedAt = fetchedAt;
	}

	/// Records a provider failure. The last good data stays available.
	void recordProviderError(String providerId, AppError error) {
		_providerErrors[providerId] = error;
	}

	void clearProviderError(String providerId) {
		_providerErrors.remove(providerId);
	}

	/// Restores data from the on-disk cache.
	void restoreFromCache() {
		final cached = cache.read();
		final value = cached.valueOrNull;
		if (value == null) {
			_servers = const [];
			_fetchedAt = null;
			return;
		}
		_servers = List.unmodifiable(value.servers);
		_fetchedAt = value.fetchedAt;
	}

	/// Persists the current contents.
	void persist() {
		final at = _fetchedAt;
		if (at == null || _servers.isEmpty) {
			return;
		}
		cache.write(_servers, at);
	}

	DirectorySnapshot snapshot() {
		final byCountry = <String, List<VpnServer>>{};
		for (final server in _servers) {
			byCountry.putIfAbsent(server.countryCode, () => <VpnServer>[]).add(server);
		}
		return DirectorySnapshot(
			servers: servers,
			state: state,
			byCountry: Map.unmodifiable(byCountry),
			lastFetchedAt: _fetchedAt,
			providerErrors: providerErrors,
		);
	}

	/// Merges fresh provider output with anything already held.
	///
	/// Servers that only exist locally (imports, favorites) are preserved;
	/// providers that did not report this round keep their last-known data so
	/// one dead provider does not empty the country list.
	static List<VpnServer> merge(
		List<VpnServer> fresh, {
		required List<VpnServer> previous,
		required String providerId,
	}) =>
			ServerMerger.merge(
				fresh,
				previous: previous,
				providerId: providerId,
			);
}
