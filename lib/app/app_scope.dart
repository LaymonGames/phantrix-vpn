library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:phantrix_core/phantrix_core.dart';
import 'package:phantrix_platform/phantrix_platform.dart';

import '../discovery/discovery_controller.dart';
import '../discovery/file_directory_cache.dart';
import '../discovery/file_vpn_gate_profile_cache.dart';
import '../l10n/strings.dart';
import '../net/app_http_fetcher.dart';
import '../settings/settings_controller.dart';
import '../settings/settings_persistence.dart';
import '../storage/app_store.dart';
import '../vpn/connection_controller.dart';
import '../vpn/connection_resolver.dart';
import '../vpn/relay_probe.dart';

part 'app_scope_connections.dart';

/// Wiring for the whole app, created once above [MaterialApp] so no widget
/// rebuilds a controller.
///
/// [bootstrap] builds the real scope and is the only thing that touches the
/// disk or a platform channel. Everything else — including every widget test —
/// uses [AppScope.inMemory], which is why the app's own test suite needs no
/// device and no temporary directories.
class AppScope {
  /// Builds a scope with no persistence and no platform storage.
  ///
  /// The store is in-memory, so a test can run the whole app repeatedly with
  /// no leftovers between runs.
  factory AppScope.inMemory({
    SettingsController? settings,
    List<ServerProvider>? providers,
    HttpFetcher? fetcher,
  }) {
    return AppScope._(
      store: MemoryAppStore(),
      settings: settings,
      providers: providers,
      fetcher: fetcher,
      initialSettings: settings?.data,
    );
  }

  AppScope._({
    required AppStore store,
    required List<ServerProvider>? providers,
    required HttpFetcher? fetcher,
    required AppSettings? initialSettings,
    SettingsController? settings,
    DirectoryCache? directoryCache,
    VpnGateProfileCache? profileCache,
  }) {
    _ownsFetcher = fetcher == null;
    _fetcher = fetcher ?? AppHttpFetcher.owned();
    _platform = PhantrixPlatform();
    // When the caller supplies a controller, that controller is used
    // unchanged — a test's controller is the one under test, and replacing
    // it would quietly discard the settings the test set up.
    _settings =
        settings ??
        PersistentSettingsController(
          initialSettings ?? AppSettings.defaults,
          store,
        );
    discovery = DiscoveryController(
      providers:
          providers ??
          buildProviders(
            enabled: const {ProviderId.vpnGate},
            fetcher: _fetcher,
            profileCache: profileCache,
          ),
      cache: directoryCache,
    );
    connection = ConnectionController(
      platform: _platform,
      settings: _settings,
      // The flow's sentences follow the language the user set, re-read on
      // every message so a settings change lands on the next sentence.
      language: () => L10n(_settings.data.language),
    );
    resolver = ConnectionResolver(
      discovery: discovery,
      relayProbe: tcpRelayProbe,
      language: () => L10n(_settings.data.language),
    );
    // A retry after "there was nothing to connect to" can only be fixed
    // by selecting again, and only this scope knows how to do that — the
    // resolver and the discovery controller live here. Handing the
    // controller the method keeps `retry` honest: it re-selects when
    // nothing was ever attempted, and replays the recorded attempt when
    // something was.
    connection.retrySelection = connect;
  }

  /// Builds the real scope: opens the platform's private directory, reads the
  /// stored settings, and prepares everything the UI needs before the first
  /// frame.
  ///
  /// A failure here is deliberately not fatal. An app that cannot read its
  /// store still runs with defaults, because "your settings did not load" is
  /// a worse experience than "your settings went back to how they were".
  static Future<AppScope> bootstrap({
    List<ServerProvider>? providers,
    HttpFetcher? fetcher,
    PhantrixPlatform? platform,
  }) async {
    final bridge = platform ?? PhantrixPlatform();
    final directory = await _privateDirectory(bridge);
    final store = await openDefaultStore(directory);
    final settings = await PersistentSettingsController.loadFrom(store);
    // The stored preference is the truth about starting at sign-in, and the
    // entry in the shell's start-up list is only its mechanism: stating it
    // again on every launch repairs an installation that has moved and
    // removes an entry left behind by a switch that was turned off.
    unawaited(bridge.setStartOnBoot(settings.startOnBoot));
    return AppScope._(
      store: store,
      providers: providers,
      fetcher: fetcher,
      initialSettings: settings,
      directoryCache: directory == null
          ? null
          : FileDirectoryCache.inDirectory(directory),
      profileCache: directory == null
          ? null
          : FileVpnGateProfileCache.inDirectory(directory),
    );
  }

  late final PhantrixPlatform _platform;
  late final SettingsController _settings;
  late final HttpFetcher _fetcher;

  /// True when this scope created the fetcher and so owns its socket.
  late final bool _ownsFetcher;
  late final DiscoveryController discovery;
  late final ConnectionController connection;
  late final ConnectionResolver resolver;

  SettingsController get settingsController => _settings;

  Future<void> dispose() async {
    await discovery.dispose();
    connection.dispose();
    _platform.dispose();
    _settings.dispose();
    if (_ownsFetcher) {
      (_fetcher as AppHttpFetcher).close();
    }
  }
}
