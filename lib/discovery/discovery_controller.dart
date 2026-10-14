import 'dart:async';

import 'package:phantrix_core/phantrix_core.dart';

/// Which providers are enabled.
///
/// VPN Gate is the one public feed this build ships with. `imported` is not a
/// fetch at all: it is the user's own configurations, held by
/// `ConfigurationRepository`, and it exists as a provider id so that an
/// imported configuration is attributed to a source rather than appearing as
/// an unattributed row.
///
/// The manifest provider needs a signed manifest URL that this project does not
/// host yet, so it is not offered in the UI as though it worked.
enum ProviderId {
	vpnGate('vpngate'),
	imported('imported');

	const ProviderId(this.wireName);

	final String wireName;

	/// Whether this provider needs the network.
	///
	/// `imported` does not, so the discovery layer must not try to fetch it —
	/// doing so would report an unreachable-provider error for something that
	/// never needed the network in the first place.
	bool get requiresNetwork => this != ProviderId.imported;

	static ProviderId? fromWire(String value) {
		for (final id in ProviderId.values) {
			if (id.wireName == value) {
				return id;
			}
		}
		return null;
	}
}

/// Runs the providers and publishes a merged directory snapshot.
///
/// Responsibilities, kept out of the UI:
///
///  * fetch every enabled provider, concurrently;
///  * record each provider's failure without discarding the others' data,
///    so one dead feed cannot empty the country list;
///  * publish a [DirectorySnapshot] on every change;
///  * refuse overlapping refreshes instead of racing them.
///
/// It never invents a server, a latency or a status. If every provider fails,
/// the snapshot says so.
class DiscoveryController {
	/// Creates a controller over [providers].
	///
	/// [cache] is injectable for tests; the default is [MemoryDirectoryCache].
	/// The directory and the cache are deliberately built from the *same*
	/// resolved cache instance, so what the directory holds and what the cache
	/// was asked to persist can never diverge.
	factory DiscoveryController({
		required List<ServerProvider> providers,
		DirectoryCache? cache,
	}) {
		final resolved = cache ?? MemoryDirectoryCache();
		return DiscoveryController._(
			List.unmodifiable(providers),
			resolved,
			ServerDirectory(cache: resolved),
		);
	}

	DiscoveryController._(this._providers, this._cache, this._directory);

	final List<ServerProvider> _providers;
	final DirectoryCache _cache;
	final ServerDirectory _directory;

	final _snapshots = StreamController<DirectorySnapshot>.broadcast();

	/// Emits on every change. Broadcast, so the settings screen and the
	/// locations screen can both listen.
	Stream<DirectorySnapshot> get snapshots => _snapshots.stream;

	/// The current data, for a first paint that does not have to wait for a
	/// refresh.
	DirectorySnapshot get snapshot => _directory.snapshot();

	/// The provider that owns [server], or null when none is registered.
	///
	/// A configuration can only be fetched from the source that published the
	/// server: a WireGuard configuration from one feed is meaningless to
	/// another. Returning null rather than guessing keeps the UI honest when a
	/// provider has been disabled since the list was fetched.
	ServerProvider? providerFor(VpnServer server) {
		for (final provider in _providers) {
			if (provider.id == server.providerId) {
				return provider;
			}
		}
		return null;
	}

	/// Ids of every registered provider, for diagnostics.
	List<String> get providerIds =>
			_providers.map((p) => p.id).toList(growable: false);

	bool _refreshing = false;
	bool _hasLiveDirectoryData = false;
	Future<DirectorySnapshot>? _refreshFuture;

	/// True while a refresh is in flight, so the UI can show progress instead
	/// of an indeterminate spinner.
	bool get isRefreshing => _refreshing;

	/// Whether this process has received server records from a provider.
	/// This is a freshness signal, not a connection gate: the app may still try
	/// a saved relay when a feed is unavailable if its cached profile validates.
	bool get hasLiveDirectoryData => _hasLiveDirectoryData;

	/// Waits for a provider refresh when the caller has no directory at all.
	/// A restored directory can be used immediately: its matching public
	/// profile may also be cached, and the provider can refresh on demand if an
	/// older installation saved metadata without profiles.
	Future<DirectorySnapshot> ensureLoaded() {
		final active = _refreshFuture;
		if (active != null) {
			return active;
		}
		if (_hasLiveDirectoryData && _directory.snapshot().servers.isNotEmpty) {
			return Future.value(_directory.snapshot());
		}
		return refresh();
	}

	/// Restores cached public metadata for immediate first paint. The provider's
	/// separate profile cache is restored independently; a live refresh is still
	/// started in the background but is no longer a prerequisite for trying a
	/// previously saved relay.
	void restoreFromCache() {
		_directory.restoreFromCache();
		_hasLiveDirectoryData = false;
		_emit();
	}

	/// Fetches every provider and merges the results.
	///
	/// Returns the snapshot that resulted. Provider failures are recorded in
	/// [DirectorySnapshot.providerErrors] rather than thrown, because a
	/// partial server list is more useful than none.
	Future<DirectorySnapshot> refresh({bool force = false}) {
		final active = _refreshFuture;
		if (active != null) {
			return active;
		}
		final future = _refreshInternal(force: force);
		_refreshFuture = future;
		return future;
	}

	Future<DirectorySnapshot> _refreshInternal({required bool force}) async {
		_refreshing = true;
		_emit();
		try {
			final outcomes = await Future.wait(
				_providers.map((provider) => _runOne(provider, force: force)),
			);

			// Merged sequentially, not independently. Merging each provider
			// against the *previous* directory and then concatenating would
			// re-inject every other provider's servers on each pass, so the
			// same endpoint would appear once per provider.
			var merged = <VpnServer>[];
			var anySucceeded = false;
			var hasFreshData = false;
			DateTime? newestFetchedAt;
			for (final outcome in outcomes) {
				if (outcome.servers.isEmpty) {
					continue;
				}
				anySucceeded = true;
				hasFreshData = hasFreshData || !outcome.usedCache;
				final fetchedAt = outcome.fetchedAt;
				if (fetchedAt != null &&
						(newestFetchedAt == null || fetchedAt.isAfter(newestFetchedAt))) {
					newestFetchedAt = fetchedAt;
				}
				merged = ServerDirectory.merge(
					outcome.servers,
					previous: merged,
					providerId: outcome.providerId,
				);
			}

			if (!anySucceeded || merged.isEmpty) {
				// Nothing came back. Keep whatever was held rather than
				// replacing a good list with nothing, and let the snapshot's
				// providerErrors explain why.
				_emit();
				return _directory.snapshot();
			}

			final fetchedAt = hasFreshData
					? (newestFetchedAt ?? DateTime.now())
					: (newestFetchedAt ?? _directory.snapshot().lastFetchedAt ?? DateTime.now());
			_directory.replaceAll(merged, fetchedAt);
			_hasLiveDirectoryData = true;
			// Rewriting the on-disk cache for an in-memory cache hit would make
			// old server data appear newer than it really is.
			if (hasFreshData) {
				_cache.write(merged, fetchedAt);
			}
			_emit();
			return _directory.snapshot();
		} finally {
			_refreshing = false;
			_refreshFuture = null;
			_emit();
		}
	}

	Future<_Outcome> _runOne(ServerProvider provider, {required bool force}) async {
		try {
			final result = await provider.refresh(force: force);
			if (result.isOk) {
				_directory.clearProviderError(provider.id);
			} else {
				_directory.recordProviderError(provider.id, result.error!);
			}
			return _Outcome(
				provider.id,
				result.servers,
				usedCache: result.usedCache,
				fetchedAt: result.fetchedAt,
			);
		} catch (error) {
			// A provider that throws violates its own contract. Treat it as a
			// failure rather than letting it take the whole refresh down.
			_directory.recordProviderError(
				provider.id,
				AppError(
					group: ErrorGroup.provider,
					code: 'provider.threw',
					message: 'A server source failed unexpectedly.',
					detail: {'cause': error.runtimeType.toString()},
				),
			);
			return _Outcome(provider.id, const [], usedCache: false, fetchedAt: null);
		}
	}

	void _emit() {
		if (!_snapshots.isClosed) {
			_snapshots.add(_directory.snapshot());
		}
	}

	Future<void> dispose() async {
		await _snapshots.close();
	}
}

class _Outcome {
	const _Outcome(
		this.providerId,
		this.servers, {
		required this.usedCache,
		required this.fetchedAt,
	});

	final String providerId;
	final List<VpnServer> servers;
	final bool usedCache;
	final DateTime? fetchedAt;
}

/// Builds the provider list for the given enablement.
///
/// Returns an empty list when nothing is enabled, which the controller
/// reports as "no sources enabled" rather than as "no servers found".
List<ServerProvider> buildProviders({
	required Set<ProviderId> enabled,
	required HttpFetcher fetcher,
	VpnGateProfileCache? profileCache,
}) =>
		[
			for (final id in enabled)
				if (id == ProviderId.vpnGate)
					VpnGateProvider(fetcher: fetcher, profileCache: profileCache),
		];
