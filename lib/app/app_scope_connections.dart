part of 'app_scope.dart';

extension AppScopeConnections on AppScope {
  /// Connects using the user's saved settings and no country constraint.
  ///
  /// This is the path the Connect button takes. It goes through the resolver
  /// rather than calling [ConnectionController.connect] directly, because a
  /// connection needs a *selected server plus its configuration*, and only
  /// the resolver knows how to obtain the second.
  Future<void> connect() async {
    // If a saved directory exists for the selected country, attempt it
    // immediately. A background feed refresh must not block VPN startup,
    // and cached public profiles can still be re-validated and tried.
    final remembered = _settings.data.selectedCountryCode;
    final countryCode = remembered == 'AUTO' ? null : remembered;
    if (discovery.snapshot.servers.isEmpty) {
      // With no saved candidates there is nothing to dial yet, so let the
      // initial load finish. Once any directory is available, selection
      // proceeds immediately without waiting for a live refresh.
      await discovery.ensureLoaded();
    }
    if (discovery.snapshot.servers.isEmpty) {
      connection.reportSelectionFailure(
        'No server list is available yet. Check your internet connection and '
        'retry.',
      );
      return;
    }
    // Preserve the user's location preference exactly. If it is temporarily
    // absent from the public feed, the resolver reports that instead of
    // silently sending the user to a different country.
    await resolver.resolveAndConnect(
      SelectionRequest(
        mode: SelectionMode.recommended,
        countryCode: countryCode,
        favorites: _settings.data.favoriteServers,
        recents: _settings.data.recentServers,
      ),
      connection: connection,
    );
  }

  /// Remembers the country immediately (even if its current server is down),
  /// then attempts that exact country from the current directory. A refresh
  /// is awaited only when no saved directory exists at all.
  Future<void> connectToCountry(String countryCode) async {
    // Choosing somewhere else abandons what is running now — a live tunnel
    // or an attempt still negotiating — at whatever point it had reached.
    // Done here rather than after the new server is resolved, so the old
    // tunnel is not still carrying traffic to a place the user just left
    // while the next one is looked up, and so a new country that turns out
    // to be unusable leaves the user disconnected with a reason instead of
    // silently still on the old one.
    await connection.cancel();
    final suppliedCode = countryCode.toUpperCase();
    final code = GeoDatabase.byIso3(suppliedCode)?.iso2 ?? suppliedCode;
    _settings.update(
      (settings) => settings.copyWith(selectedCountryCode: code),
    );
    if (code == 'AUTO') {
      await connect();
      return;
    }
    if (discovery.snapshot.servers.isEmpty) {
      await discovery.ensureLoaded();
    }
    if (discovery.snapshot.servers.isEmpty) {
      connection.reportSelectionFailure(
        'No server list is available yet. Check your internet connection and '
        'retry.',
      );
      return;
    }
    await resolver.resolveAndConnect(
      SelectionRequest(
        mode: SelectionMode.recommended,
        countryCode: code,
        favorites: _settings.data.favoriteServers,
        recents: _settings.data.recentServers,
      ),
      connection: connection,
    );
    // A country with only a handful of volunteer relays often fails on the
    // first pass because those relays are down. Refresh the directory and
    // try once more before giving up, so a stale list is not the reason a
    // country cannot be reached.
    if (connection.currentView.errorCode == 'tunnel.no_relay_reached') {
      await discovery.refresh(force: true);
      if (discovery.snapshot.servers.isNotEmpty) {
        await resolver.resolveAndConnect(
          SelectionRequest(
            mode: SelectionMode.recommended,
            countryCode: code,
            favorites: _settings.data.favoriteServers,
            recents: _settings.data.recentServers,
          ),
          connection: connection,
        );
      }
    }
  }
}

/// Asks the platform where private files live, with one retry.
///
/// Returns null when the platform cannot say, which the caller turns into
/// the in-memory store. A lookup that never answers must degrade rather
/// than hang the launch on a blank splash screen, so each attempt is
/// bounded — but a single slow answer must not cost the user their
/// settings either, so a first timeout retries once before giving up.
/// Five seconds is an eternity for a local directory lookup and still
/// short enough that a user watching a splash does not conclude the app
/// is dead.
///
/// Every fallback is reported, not silent: a launch that quietly forgot
/// the user's settings would be indistinguishable from data loss.
/// The one exception is a prompt null or empty answer, which is how a
/// platform without private storage (the web) legitimately responds.
Future<String?> _privateDirectory(PhantrixPlatform bridge) async {
  for (var attempt = 0; attempt < 2; attempt++) {
    try {
      final directory = await bridge.appDataDirectory().timeout(
        const Duration(seconds: 5),
      );
      // A prompt null or empty answer is a legitimate "there is
      // nowhere to persist" (the web), not a failure: silent.
      if (directory == null || directory.isEmpty) {
        return null;
      }
      return directory;
    } on TimeoutException {
      // A first timeout may be transient slowness on a cold device
      // rather than absence; only the second attempt is trusted.
      if (attempt == 0) {
        await Future<void>.delayed(const Duration(seconds: 1));
        continue;
      }
    } on Object catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'phantrix.storage',
          context: ErrorDescription(
            'reading the private application directory',
          ),
        ),
      );
      return null;
    }
  }
  FlutterError.reportError(
    FlutterErrorDetails(
      exception: StateError(
        'The platform did not report a private directory, so settings '
        'will not persist this launch.',
      ),
      library: 'phantrix.storage',
      context: ErrorDescription('reading the private application directory'),
    ),
  );
  return null;
}
