import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:phantrix_core/phantrix_core.dart';
import 'package:phantrix/settings/settings_controller.dart';
import 'package:phantrix/theme/app_theme.dart';
import 'package:phantrix/ui/screens/settings/connection_panel.dart';
import 'package:phantrix_platform/phantrix_platform.dart';

PlatformCapabilities windowsCapabilities({bool bootStart = true}) {
  return PlatformCapabilities(
    platformName: 'windows',
    supportsKillSwitch: false,
    supportsIpv6Blocking: false,
    supportsVpnProvidedDns: true,
    supportsPerAppSplitTunnelling: false,
    supportsLanBypass: false,
    supportsAlwaysOn: false,
    supportsTray: false,
    supportsBootStart: bootStart,
    openVpn: true,
    limitations: const {},
  );
}

Widget harness({
  required SettingsController settings,
  required PlatformCapabilities platform,
  required Future<bool> Function(bool enabled) onStartOnBootChanged,
}) {
  return MaterialApp(
    theme: AppTheme.dark(
      animationLevel: AppSettings.defaults.animationLevel,
    ),
    home: Scaffold(
      body: SingleChildScrollView(
        child: ConnectionPanel(
          settings: settings,
          platform: platform,
          onOpenSystemVpnSettings: () {},
          systemLockdownActive: () async => false,
          onStartOnBootChanged: onStartOnBootChanged,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('an accepted start-on-boot choice is what gets recorded', (
    tester,
  ) async {
    final settings = SettingsController();
    await tester.pumpWidget(
      harness(
        settings: settings,
        platform: windowsCapabilities(),
        onStartOnBootChanged: (enabled) async => true,
      ),
    );
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(settings.data.startOnBoot, isTrue);
  });

  testWidgets('a refused start-on-boot choice is not recorded, and is said', (
    tester,
  ) async {
    // The switch shows the stored preference. If a refusal were recorded
    // anyway, the screen would show a start-up the machine never agreed
    // to — so the preference must stay as it was, and the refusal must be
    // visible rather than silent.
    final settings = SettingsController();
    await tester.pumpWidget(
      harness(
        settings: settings,
        platform: windowsCapabilities(),
        onStartOnBootChanged: (enabled) async => false,
      ),
    );
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(settings.data.startOnBoot, isFalse);
    expect(find.byType(SnackBar), findsOneWidget);
    // Let the snack bar's own timer fire before the test ends.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('a platform without start-on-boot disables the switch with a reason', (
    tester,
  ) async {
    final settings = SettingsController();
    await tester.pumpWidget(
      harness(
        settings: settings,
        platform: windowsCapabilities(bootStart: false),
        onStartOnBootChanged: (enabled) async => false,
      ),
    );
    final toggle = tester.widget<Switch>(find.byType(Switch));
    expect(toggle.onChanged, isNull);
    expect(
      find.text('This platform cannot start the app on system boot.'),
      findsOneWidget,
    );
  });

  testWidgets('a platform with start-on-boot leaves the switch live', (
    tester,
  ) async {
    final settings = SettingsController();
    await tester.pumpWidget(
      harness(
        settings: settings,
        platform: windowsCapabilities(),
        onStartOnBootChanged: (enabled) async => true,
      ),
    );
    final toggle = tester.widget<Switch>(find.byType(Switch));
    expect(toggle.onChanged, isNotNull);
    expect(
      find.text('This platform cannot start the app on system boot.'),
      findsNothing,
    );
  });
}
