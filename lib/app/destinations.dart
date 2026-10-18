part of 'app_shell.dart';

List<Destination> _destinations(
  AppScope scope,
  AppNavigation navigation,
  bool reducedMotion,
) => [
  Destination(
    id: 'home',
    label: 'Home',
    icon: Icons.shield_outlined,
    selectedIcon: Icons.shield_rounded,
    builder: (context) => HomeScreen(
      connection: scope.connection,
      reducedMotion: reducedMotion,
      selectedCountryCode: scope.settingsController.data.selectedCountryCode,
      onQuickConnect: scope.connect,
      onChooseLocation: () => navigation.go('locations'),
    ),
  ),
  Destination(
    id: 'locations',
    label: 'Servers',
    icon: Icons.public_outlined,
    selectedIcon: Icons.public,
    builder: (context) => DiscoveryGate(
      controller: scope.discovery,
      selectedCountryCode: scope.settingsController.data.selectedCountryCode,
      onCountrySelected: scope.connectToCountry,
      openVpnSupported: scope.connection.capabilities.openVpn,
    ),
  ),
  Destination(
    id: 'diagnostics',
    label: 'Diagnostics',
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
    id: 'settings',
    label: 'Settings',
    icon: Icons.settings_outlined,
    selectedIcon: Icons.settings_rounded,
    builder: (context) => SettingsScreen(
      settings: scope.settingsController,
      platform: scope.connection.capabilities,
      onOpenDiagnostics: () => navigation.go('diagnostics'),
      onOpenSystemVpnSettings: () =>
          unawaited(scope.connection.openSystemVpnSettings()),
      systemLockdownActive: scope.connection.systemLockdownActive,
      onClearLocalData: scope.settingsController.clearLocalData,
    ),
  ),
];
