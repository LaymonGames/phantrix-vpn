import 'package:flutter/widgets.dart';

import 'package:phantrix_core/phantrix_core.dart';

/// Live settings held by the app.
///
/// Extends [ChangeNotifier] so every screen rebuilds from one place and no
/// screen keeps a second copy of the settings.
///
/// This base class keeps nothing on disk. [PersistentSettingsController] is the
/// one the app runs, and it adds storage. The split is what lets a widget test
/// construct a controller with no filesystem and no platform channel, which is
/// why the app's own tests do not need a device to exercise settings.
class SettingsController extends ChangeNotifier {
  SettingsController([this.data = AppSettings.defaults]);

  AppSettings data;

  /// Applies [change] and tells every listener.
  void update(AppSettings Function(AppSettings) change) {
    data = change(data);
    notifyListeners();
  }

  /// Records that [serverId] was just used, most recent first.
  ///
  /// Capped so the list cannot grow without bound, which matters because it
  /// is written to disk on every connection.
  void noteUsed(String serverId) {
    update(
      (current) => current.copyWith(
        recentServers: [
          serverId,
          ...current.recentServers.where((id) => id != serverId),
        ].take(10).toList(),
      ),
    );
  }

  /// Adds or removes [serverId] from the favourites.
  ///
  /// Returns the state after the change, so a caller can report "added" or
  /// "removed" without re-reading the list.
  bool toggleFavorite(String serverId) {
    final isFavorite = data.favoriteServers.contains(serverId);
    update(
      (current) => current.copyWith(
        favoriteServers: [
          if (!isFavorite) serverId,
          ...current.favoriteServers.where((id) => id != serverId),
        ].toList(),
      ),
    );
    return !isFavorite;
  }

  /// Clears everything the app keeps locally.
  ///
  /// The onboarding flags are deliberately kept: a user who clears their
  /// data should not be made to re-read the privacy notice, and being forced
  /// back through it is not what "clear" means to them.
  void clearLocalData() {
    // Route the reset through update() so persistent controllers write the
    // defaults as well as notifying the UI. Directly changing `data` here
    // used to reset the screen but bring the old country back on restart.
    update(
      (current) => current.copyWith(
        customDns: const [],
        trustedNetworks: const [],
        favoriteCountries: const [],
        selectedCountryCode: 'AUTO',
        favoriteServers: const [],
        recentServers: const [],
        clearedHistoryAt: DateTime.now(),
      ),
    );
  }
}
