library;

import 'dart:async';

import 'package:phantrix_core/phantrix_core.dart';

part 'provider_id.dart';
part 'discovery_outcome.dart';
part 'discovery_refresh.dart';

List<ServerProvider> buildProviders({
  required Set<ProviderId> enabled,
  required HttpFetcher fetcher,
  VpnGateProfileCache? profileCache,
}) => [
  for (final id in enabled)
    if (id == ProviderId.vpnGate)
      VpnGateProvider(fetcher: fetcher, profileCache: profileCache),
];

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
  /// server: a profile from one feed is meaningless to another. Returning
  /// null rather than guessing keeps the UI honest when a provider has been
  /// disabled since the list was fetched.
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
}
