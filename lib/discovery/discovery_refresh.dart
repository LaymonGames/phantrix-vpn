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

      // A new feed must not erase what the user already had. Servers from
      // the previous list that the feed no longer mentions are kept (the
      // feed drops volunteer relays that blink offline and brings them
      // back), until they have gone unseen for a week or the cache limit is
      // reached. Their resolved states are remembered too, so reopening the
      // app does not look every address up again.
      final previous = _directory.servers;
      for (final server in previous) {
        final ip = server.hostAddress;
        final region = server.region;
        if (ip != null && region != null && region.trim().isNotEmpty) {
          _regions[ip] = region;
        }
      }
      merged = List<VpnServer>.of(merged);
      final seen = merged.map(ServerMerger.key).toSet();
      final cutoff = DateTime.now().subtract(const Duration(days: 7));
      for (final server in previous) {
        final lastSeen = server.lastSeenAt;
        if (merged.length >= 2000 ||
            seen.contains(ServerMerger.key(server)) ||
            (lastSeen != null && lastSeen.isBefore(cutoff))) {
          continue;
        }
        // Kept for the list, but marked unverified: the feed stopped
        // vouching for it, so automatic selection must prefer relays the
        // feed lists now. The resolver still reaches it as a last resort.
        merged.add(
          server.status == ServerStatus.withdrawn
              ? server
              : server.copyWith(status: ServerStatus.unknown),
        );
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
      // States are looked up after the list is published, so a slow or
      // unreachable lookup service never delays the country list.
      unawaited(_enrichRegions());
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

  /// Gives every server without a state the one its IP resolves to.
  Future<void> _enrichRegions() async {
    final lookup = _regionLookup;
    if (lookup == null || _enriching) {
      return;
    }
    _enriching = true;
    try {
      for (final server in _directory.servers) {
        final ip = server.hostAddress;
        final region = server.region;
        if (ip != null && region != null && region.trim().isNotEmpty) {
          _regions[ip] = region;
        }
      }
      final missing = <String>{
        for (final server in _directory.servers)
          if (server.hostAddress != null &&
              !_regions.containsKey(server.hostAddress) &&
              !_unresolvable.contains(server.hostAddress))
            server.hostAddress!,
      }.toList(growable: false);
      if (missing.isNotEmpty) {
        final found = await lookup(missing);
        _regions.addAll(found);
        _unresolvable.addAll(missing.where((ip) => !found.containsKey(ip)));
      }
      var changed = false;
      final updated = [
        for (final server in _directory.servers)
          if ((server.region == null || server.region!.trim().isEmpty) &&
              _regions[server.hostAddress] != null)
            (() {
              changed = true;
              return server.copyWith(region: _regions[server.hostAddress]);
            })()
          else
            server,
      ];
      final at = _directory.snapshot().lastFetchedAt;
      if (changed && at != null) {
        _directory.replaceAll(updated, at);
        _directory.persist();
        _emit();
      }
    } on Object {
      // Best effort: without states a country still offers "Fastest".
    } finally {
      _enriching = false;
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
