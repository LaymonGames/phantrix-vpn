import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:phantrix_core/phantrix_core.dart';
import 'package:phantrix_platform/phantrix_platform.dart';

import 'package:phantrix/l10n/strings.dart';
import 'package:phantrix/settings/settings_controller.dart';
import 'package:phantrix/theme/app_theme.dart';
import 'package:phantrix/ui/components/connection_orb.dart';
import 'package:phantrix/ui/screens/home_screen.dart';
import 'package:phantrix/ui/screens/settings/connection_panel.dart';
import 'package:phantrix/vpn/connection_controller.dart';

PlatformCapabilities _windows() => const PlatformCapabilities(
  platformName: 'windows',
  supportsKillSwitch: true,
  supportsIpv6Blocking: false,
  supportsVpnProvidedDns: true,
  supportsPerAppSplitTunnelling: false,
  supportsLanBypass: false,
  supportsAlwaysOn: false,
  supportsTray: false,
  supportsBootStart: true,
  openVpn: true,
  limitations: {},
);

const _releaseError = AppError(
  group: ErrorGroup.unknown,
  code: 'kill_switch.release_failed',
  message: 'The administrator prompt was declined.',
);

/// A bridge whose kill switch state the test sets, and whose release the
/// test can hold open to watch the screen while it runs.
class _KillSwitchBridge extends PhantrixPlatform {
  final _events = StreamController<PlatformEvent>.broadcast();

  KillSwitchState state = KillSwitchState.inactive;
  int releaseCalls = 0;
  Completer<Result<void>>? releaseGate;

  @override
  Stream<PlatformEvent> get events => _events.stream;

  @override
  Future<PlatformCapabilities> capabilities() async => _windows();

  @override
  Future<KillSwitchState> killSwitchState() async => state;

  @override
  Future<Result<void>> releaseKillSwitch() async {
    releaseCalls++;
    final gate = releaseGate;
    final result = gate == null ? const Ok<void>(null) : await gate.future;
    if (result.errorOrNull == null) {
      state = KillSwitchState.inactive;
    }
    return result;
  }

  @override
  Future<Result<void>> stopTunnel({bool keepBlocking = false}) async =>
      const Ok(null);

  @override
  void dispose() {
    unawaited(_events.close());
  }
}

Widget _panel({
  required SettingsController settings,
  bool blocking = false,
  Future<Result<void>> Function()? onRelease,
  Future<void> Function()? onRefresh,
}) {
  return MaterialApp(
    theme: AppTheme.dark(animationLevel: AppSettings.defaults.animationLevel),
    home: Scaffold(
      body: SingleChildScrollView(
        child: AnimatedBuilder(
          animation: settings,
          builder: (context, _) => ConnectionPanel(
            settings: settings,
            platform: _windows(),
            onOpenSystemVpnSettings: () {},
            systemLockdownActive: () async => false,
            onStartOnBootChanged: (_) async => true,
            killSwitchBlocking: () => blocking,
            onReleaseKillSwitch: onRelease,
            onRefreshKillSwitch: onRefresh,
          ),
        ),
      ),
    ),
  );
}

void main() {
  final en = L10n.en;

  group('settings kill switch row', () {
    testWidgets('Strict asks first; Cancel keeps the previous mode', (
      tester,
    ) async {
      final settings = SettingsController();
      expect(settings.data.killSwitch, KillSwitchMode.automatic);
      await tester.pumpWidget(_panel(settings: settings));

      await tester.tap(find.text(en.get('killSwitchStrict')));
      await tester.pumpAndSettle();
      expect(find.text(en.get('killSwitchStrictConfirmTitle')), findsOneWidget);
      expect(find.text(en.get('killSwitchStrictConfirmBody')), findsOneWidget);

      await tester.tap(find.text(en.get('cancel')));
      await tester.pumpAndSettle();
      expect(find.text(en.get('killSwitchStrictConfirmTitle')), findsNothing);
      expect(settings.data.killSwitch, KillSwitchMode.automatic);
    });

    testWidgets('Strict is recorded once confirmed, then state re-read', (
      tester,
    ) async {
      final settings = SettingsController();
      var refreshes = 0;
      await tester.pumpWidget(
        _panel(settings: settings, onRefresh: () async => refreshes++),
      );

      await tester.tap(find.text(en.get('killSwitchStrict')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(en.get('killSwitchStrictConfirm')));
      await tester.pumpAndSettle();

      expect(settings.data.killSwitch, KillSwitchMode.strict);
      expect(refreshes, 1);
      expect(find.text(en.get('killSwitchStrictHint')), findsOneWidget);
    });

    testWidgets('Off while blocking lifts the block; a failure is said', (
      tester,
    ) async {
      final settings = SettingsController();
      var releases = 0;
      await tester.pumpWidget(
        _panel(
          settings: settings,
          blocking: true,
          onRelease: () async {
            releases++;
            return const Err(_releaseError);
          },
        ),
      );

      await tester.tap(find.text(en.get('killSwitchOff')));
      await tester.pumpAndSettle();

      expect(settings.data.killSwitch, KillSwitchMode.off);
      expect(releases, 1);
      expect(find.text(en.get('killSwitchReleaseFailed')), findsOneWidget);
    });

    testWidgets('Automatic to Off with nothing blocking does not release', (
      tester,
    ) async {
      final settings = SettingsController();
      var releases = 0;
      await tester.pumpWidget(
        _panel(
          settings: settings,
          onRelease: () async {
            releases++;
            return const Ok(null);
          },
        ),
      );
      await tester.tap(find.text(en.get('killSwitchOff')));
      await tester.pumpAndSettle();
      expect(settings.data.killSwitch, KillSwitchMode.off);
      expect(releases, 0);
    });
  });

  group('home kill switch card', () {
    late _KillSwitchBridge bridge;
    late ConnectionController controller;
    late int connects;

    Future<void> pumpHome(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      // The controller reads the state once on start-up, before the test
      // set it; read it again the way a settings change would.
      await controller.refreshKillSwitch();
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(
            animationLevel: AppSettings.defaults.animationLevel,
          ),
          home: Scaffold(
            body: HomeScreen(
              connection: controller,
              reducedMotion: true,
              onQuickConnect: () async => connects++,
              onChooseLocation: () {},
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    setUp(() {
      bridge = _KillSwitchBridge();
      controller = ConnectionController(
        platform: bridge,
        settings: SettingsController(),
      );
      connects = 0;
    });

    tearDown(() => controller.dispose());

    testWidgets('no card while the kill switch is not blocking', (
      tester,
    ) async {
      await pumpHome(tester);
      expect(find.byKey(const ValueKey('home-kill-switch-card')), findsNothing);
    });

    testWidgets('strict block is shown; Unblock lifts it with progress', (
      tester,
    ) async {
      bridge.state = const KillSwitchState(active: true, mode: 'strict');
      bridge.releaseGate = Completer<Result<void>>();
      await pumpHome(tester);

      expect(
        find.byKey(const ValueKey('home-kill-switch-card')),
        findsOneWidget,
      );
      expect(find.text(en.get('homeKillSwitchStrict')), findsOneWidget);

      await tester.tap(find.text(en.get('homeKillSwitchUnblock')));
      await tester.pump();
      expect(bridge.releaseCalls, 1);
      expect(find.text(en.get('homeKillSwitchUnblocking')), findsOneWidget);
      expect(find.text(en.get('homeKillSwitchUnblock')), findsNothing);

      bridge.releaseGate!.complete(const Ok(null));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('home-kill-switch-card')), findsNothing);
    });

    testWidgets('automatic hold after a drop; a failed unblock is said', (
      tester,
    ) async {
      bridge.state = const KillSwitchState(active: true, mode: 'automatic');
      bridge.releaseGate = Completer<Result<void>>()
        ..complete(const Err(_releaseError));
      await pumpHome(tester);

      expect(find.text(en.get('homeKillSwitchAutomatic')), findsOneWidget);
      await tester.tap(find.text(en.get('homeKillSwitchUnblock')));
      await tester.pump();
      await tester.pump();

      expect(bridge.releaseCalls, 1);
      expect(find.text(en.get('killSwitchReleaseFailed')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('home-kill-switch-card')),
        findsOneWidget,
      );
      // The button is back so the user can try again.
      expect(find.text(en.get('homeKillSwitchUnblock')), findsOneWidget);
    });

    testWidgets('connecting still works while the card is shown', (
      tester,
    ) async {
      bridge.state = const KillSwitchState(active: true, mode: 'strict');
      await pumpHome(tester);
      expect(
        find.byKey(const ValueKey('home-kill-switch-card')),
        findsOneWidget,
      );
      await tester.tap(find.byType(ConnectionOrb));
      await tester.pump();
      expect(connects, 1);
    });
  });
}
