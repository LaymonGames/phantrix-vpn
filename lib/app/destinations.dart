part of 'app_shell.dart';

List<Destination> _destinations(
  AppScope scope,
  AppNavigation navigation,
  bool reducedMotion,
) {
  final l10n = L10n(scope.settingsController.data.language);
  return [
    Destination(
      id: 'home',
      label: l10n.get('home'),
      icon: Icons.shield_outlined,
      selectedIcon: Icons.shield_rounded,
      builder: (context) => HomeScreen(
        connection: scope.connection,
        reducedMotion: reducedMotion,
        selectedCountryCode: scope.settingsController.data.selectedCountryCode,
        onQuickConnect: scope.connect,
        onChooseLocation: () => navigation.go('locations'),
        settings: scope.settingsController.data,
        onOpenSettings: () => navigation.go('settings'),
      ),
    ),
    Destination(
      id: 'locations',
      label: l10n.get('servers'),
      icon: Icons.public_outlined,
      selectedIcon: Icons.public,
      builder: (context) => DiscoveryGate(
        controller: scope.discovery,
        selectedCountryCode: scope.settingsController.data.selectedCountryCode,
        selectedRegion: scope.settingsController.data.selectedRegion,
        onCountrySelected: scope.connectToCountry,
        onRegionSelected: scope.connectToCountry,
        openVpnSupported: scope.connection.capabilities.openVpn,
      ),
    ),
    Destination(
      id: 'diagnostics',
      label: l10n.get('diagnostics'),
      icon: Icons.insights_outlined,
      selectedIcon: Icons.insights,
      // Secondary like configs: opened from Settings rather than a tab,
      // so it stays reachable without crowding the bottom bar. Its
      // parent is the Settings tab it is opened from.
      parentId: 'settings',
      builder: (context) => DiagnosticsScreen(
        connection: _ConnectionGateway(scope.connection),
        settings: scope.settingsController,
      ),
    ),
    Destination(
      id: 'licenses',
      label: l10n.get('licensesTitle'),
      icon: Icons.gavel_outlined,
      selectedIcon: Icons.gavel_rounded,
      // Secondary for the same reason as diagnostics: it is a screen a user
      // visits deliberately, and Settings is where they look for it. It was
      // missing entirely — the notice inventory had no screen consuming it —
      // so the credits this project owes went unshown.
      parentId: 'settings',
      builder: (context) => LicensesScreen(reducedMotion: reducedMotion),
    ),
    Destination(
      id: 'split-tunneling',
      label: l10n.get('settingsSplitTunneling'),
      icon: Icons.call_split_outlined,
      selectedIcon: Icons.call_split_rounded,
      // Secondary: opened from the Split tunneling panel in Settings, which
      // is where a user looks for a routing preference, and kept out of the
      // tabs because the screen is a picker rather than a destination to
      // live in.
      parentId: 'settings',
      builder: (context) => SplitTunnelingScreen(
        settings: scope.settingsController,
        connection: scope.connection,
      ),
    ),
    Destination(
      id: 'settings',
      label: l10n.get('settings'),
      icon: Icons.settings_outlined,
      selectedIcon: Icons.settings_rounded,
      builder: (context) => SettingsScreen(
        settings: scope.settingsController,
        platform: scope.connection.capabilities,
        onOpenDiagnostics: () => navigation.go('diagnostics'),
        onOpenLicenses: () => navigation.go('licenses'),
        onOpenSystemVpnSettings: () =>
            unawaited(scope.connection.openSystemVpnSettings()),
        systemLockdownActive: scope.connection.systemLockdownActive,
        onStartOnBootChanged: scope.connection.setStartOnBoot,
        onOpenSplitTunneling: () => navigation.go('split-tunneling'),
        // The settings switch stores the choice itself; this only pushes it
        // to a tunnel that is already running.
        onApplySplitTunnelLive: (policy) async => scope.connection.hasLiveTunnel
            ? await scope.connection.applySplitTunnel(policy)
            : null,
        killSwitchBlocking: () =>
            scope.connection.currentView.killSwitchBlocking,
        onReleaseKillSwitch: scope.connection.releaseKillSwitch,
        onEngageKillSwitch: scope.connection.engageStrictKillSwitch,
        onRefreshKillSwitch: scope.connection.refreshKillSwitch,
        onClearLocalData: scope.settingsController.clearLocalData,
      ),
    ),
  ];
}
