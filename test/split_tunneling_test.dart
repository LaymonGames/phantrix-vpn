import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:phantrix/settings/settings_controller.dart';
import 'package:phantrix/theme/app_theme.dart';
import 'package:phantrix/theme/tokens.dart';
import 'package:phantrix/ui/components/surfaces.dart';
import 'package:phantrix/ui/screens/settings/split_tunnel_panel.dart';
import 'package:phantrix/ui/screens/settings/split_tunneling_screen.dart';
import 'package:phantrix/vpn/connection_controller.dart';
import 'package:phantrix_core/phantrix_core.dart';
import 'package:phantrix_platform/phantrix_platform.dart';

const _chromePath = r'C:\Program Files\Google\Chrome\chrome.exe';

PlatformCapabilities _capabilities({required bool perApp}) =>
    PlatformCapabilities(
      platformName: 'windows',
      supportsKillSwitch: false,
      supportsIpv6Blocking: false,
      supportsVpnProvidedDns: true,
      supportsPerAppSplitTunnelling: perApp,
      supportsLanBypass: false,
      supportsAlwaysOn: false,
      supportsTray: false,
      supportsBootStart: true,
      openVpn: true,
      limitations: const {},
    );

/// A bridge that answers the split-tunnel calls without a method channel.
class _SplitBridge extends PhantrixPlatform {
  _SplitBridge({this.perApp = true});

  final bool perApp;
  final _events = StreamController<PlatformEvent>.broadcast();
  final applied = <SplitTunnelSettings>[];

  @override
  Stream<PlatformEvent> get events => _events.stream;

  @override
  Future<PlatformCapabilities> capabilities() async =>
      _capabilities(perApp: perApp);

  @override
  Future<List<InstalledApp>> listInstalledApps() async => const [
    InstalledApp(name: 'Chrome', path: _chromePath),
  ];

  @override
  Future<String?> appIcon(String path) async => null;

  @override
  Future<String?> pickExecutable() async => null;

  @override
  Future<Result<void>> applySplitTunnel(SplitTunnelSettings policy) async {
    applied.add(policy);
    return const Ok(null);
  }

  @override
  void dispose() {
    _events.close();
  }
}

Widget _app(Widget body) => MaterialApp(
  theme: AppTheme.dark(animationLevel: AppSettings.defaults.animationLevel),
  home: Scaffold(body: body),
);

Future<ConnectionController> _connection(
  WidgetTester tester,
  SettingsController settings, {
  bool perApp = true,
}) async {
  final bridge = _SplitBridge(perApp: perApp);
  final controller = ConnectionController(platform: bridge, settings: settings);
  addTearDown(controller.dispose);
  // Lets the capability probe started by the constructor finish.
  await tester.pump();
  return controller;
}

void main() {
  group('Split tunneling settings section', () {
    Widget panel(SettingsController settings, {required bool perApp}) => _app(
      SingleChildScrollView(
        child: AnimatedBuilder(
          animation: settings,
          builder: (context, _) => SplitTunnelPanel(
            settings: settings,
            platform: _capabilities(perApp: perApp),
            onOpenSplitTunneling: () {},
          ),
        ),
      ),
    );

    testWidgets('its switch turns split tunneling on and off', (tester) async {
      final settings = SettingsController();
      await tester.pumpWidget(panel(settings, perApp: true));

      expect(find.text('SPLIT TUNNELING'), findsOneWidget);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(settings.data.splitTunnel.enabled, isTrue);

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(settings.data.splitTunnel.enabled, isFalse);
    });

    testWidgets('it opens the app picker from its own row', (tester) async {
      final settings = SettingsController();
      var opened = 0;
      await tester.pumpWidget(
        _app(
          SplitTunnelPanel(
            settings: settings,
            platform: _capabilities(perApp: true),
            onOpenSplitTunneling: () => opened++,
          ),
        ),
      );
      await tester.tap(find.text('Applications and routing mode'));
      await tester.pumpAndSettle();
      expect(opened, 1);
    });

    testWidgets('an unsupported platform shows the switch disabled', (
      tester,
    ) async {
      final settings = SettingsController();
      await tester.pumpWidget(panel(settings, perApp: false));

      final toggle = tester.widget<Switch>(find.byType(Switch));
      expect(toggle.onChanged, isNull);
      expect(find.textContaining('signed Phantrix driver'), findsOneWidget);
    });
  });

  group('Split tunneling screen', () {
    testWidgets('every change is stored at once, with no Save step', (
      tester,
    ) async {
      final settings = SettingsController();
      final connection = await _connection(tester, settings);
      await tester.pumpWidget(
        _app(SplitTunnelingScreen(settings: settings, connection: connection)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(settings.data.splitTunnel.enabled, isTrue);
      expect(find.text('Save and apply'), findsNothing);

      await tester.tap(find.text('Chrome'));
      await tester.pumpAndSettle();
      expect(settings.data.splitTunnel.contains(_chromePath), isTrue);

      await tester.tap(find.text('Selected apps bypass VPN'));
      await tester.pumpAndSettle();
      expect(settings.data.splitTunnel.mode, SplitTunnelMode.exclude);

      // Leaving the screen keeps every choice.
      await tester.pumpWidget(_app(const SizedBox()));
      await tester.pumpAndSettle();
      expect(settings.data.splitTunnel.enabled, isTrue);
      expect(settings.data.splitTunnel.contains(_chromePath), isTrue);
      expect(settings.data.splitTunnel.mode, SplitTunnelMode.exclude);

      // Deselecting is stored the same way.
      await tester.pumpWidget(
        _app(SplitTunnelingScreen(settings: settings, connection: connection)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Chrome'));
      await tester.pumpAndSettle();
      expect(settings.data.splitTunnel.apps, isEmpty);
    });

    testWidgets('a change made elsewhere shows on the screen', (tester) async {
      final settings = SettingsController();
      final connection = await _connection(tester, settings);
      await tester.pumpWidget(
        _app(SplitTunnelingScreen(settings: settings, connection: connection)),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);

      settings.update(
        (s) => s.copyWith(splitTunnel: s.splitTunnel.copyWith(enabled: true)),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
      expect(find.text('Routing mode'.toUpperCase()), findsOneWidget);
    });
  });

  group('VgScrollColumn', () {
    testWidgets('the wheel scrolls over the page margin, not only the column', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1600, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        _app(
          VgScrollColumn(
            builder: (context, insets) => ListView(
              controller: controller,
              padding: insets,
              children: [
                for (var i = 0; i < 40; i++)
                  SizedBox(height: 80, child: Text('Row $i')),
              ],
            ),
          ),
        ),
      );

      // The content keeps the reading measure, centred.
      final row = tester.getRect(find.text('Row 0'));
      expect(row.left, greaterThan(400));
      expect(row.right, lessThan(1200));
      expect(row.left + row.right, closeTo(1600, 1));

      // A wheel event well outside the column, in the left margin.
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(pointer.hover(const Offset(40, 400)));
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, 300)));
      await tester.pumpAndSettle();
      expect(controller.offset, greaterThan(0));
    });

    test('insets match the centred column of VgContentColumn', () {
      final insets = VgScrollColumn.insetsFor(
        available: 1600,
        viewportWidth: 1600,
        maxWidth: VgSpace.maxContentWidth,
      );
      final gutter = VgSpace.gutter(1600);
      expect(insets.left, (1600 - VgSpace.maxContentWidth) / 2 + gutter);
      expect(insets.right, insets.left);

      final narrow = VgScrollColumn.insetsFor(
        available: 400,
        viewportWidth: 400,
        maxWidth: VgSpace.maxContentWidth,
      );
      expect(narrow.left, VgSpace.gutter(400));
    });
  });
}
