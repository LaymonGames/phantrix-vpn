part of 'discovery_controller.dart';

extension DiscoveryControllerRefresh on DiscoveryController {
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
          : (newestFetchedAt ??
                _directory.snapshot().lastFetchedAt ??
                DateTime.now());
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

  Future<_Outcome> _runOne(
    ServerProvider provider, {
    required bool force,
  }) async {
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
