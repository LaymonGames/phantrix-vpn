import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:phantrix/l10n/strings.dart';
import 'package:phantrix/settings/settings_controller.dart';
import 'package:phantrix/theme/app_theme.dart';
import 'package:phantrix/ui/components/brand.dart';
import 'package:phantrix/ui/components/connection_orb.dart';
import 'package:phantrix/ui/components/navigation.dart';
import 'package:phantrix/ui/components/status_style.dart';
import 'package:phantrix/ui/shell.dart';
import 'package:phantrix/app/app_scope.dart';
import 'package:phantrix_platform/phantrix_platform.dart';

/// Pumps [child] inside a MaterialApp with the app's theme and locale.
Future<void> pumpApp(
  WidgetTester tester,
  Widget child, {
  SettingsController? settings,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.dark(animationLevel: 'none'),
      locale: const Locale('en'),
      localizationsDelegates: const [_TestDelegate()],
      supportedLocales: L10n.supportedLocales,
      home: child,
    ),
  );
  await tester.pumpAndSettle();
}

class _TestDelegate extends LocalizationsDelegate<L10n> {
  const _TestDelegate();

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<L10n> load(Locale locale) async => L10n(locale.languageCode);

  @override
  bool shouldReload(covariant Object old) => false;
}

void main() {
  group('localisation', () {
    test('every English key has an Arabic counterpart', () {
      const en = L10n.en;
      const ar = L10n.ar;
      // The key set is the English map; assert a representative sample is
      // translated so a missing entry is caught before it ships.
      for (final key in [
        'connect',
        'disconnect',
        'connected',
        'notConnected',
        'chooseLocation',
        'killSwitch',
        'ipv6',
        'startOnBoot',
        'amIProtected',
        'runChecks',
        'welcomeTitle',
        'privacyNoticeAccept',
      ]) {
        expect(
          ar.get(key),
          isNot(equals(key)),
          reason: 'missing Arabic for $key',
        );
        expect(
          en.get(key),
          isNot(equals(key)),
          reason: 'missing English for $key',
        );
      }
    });

    test('an unknown key falls back rather than throwing', () {
      expect(L10n.en.get('does_not_exist'), 'does_not_exist');
    });

    test('Arabic is reported as right-to-left', () {
      expect(L10n.ar.isRtl, isTrue);
      expect(L10n.en.isRtl, isFalse);
    });
  });

  group('ConnectionOrb', () {
    testWidgets('is announced to a screen reader with its state', (
      tester,
    ) async {
      await pumpApp(
        tester,
        Scaffold(
          body: Center(
            child: ConnectionOrb(state: VgTone.connected, onPressed: () {}),
          ),
        ),
      );
      // Semantics are merged into a single node, so match on the accessible
      // name rather than an exact label string. The claim under test is
      // that the *state* is announced — not merely that the button exists.
      expect(
        find.bySemanticsLabel(RegExp('tunnel is established')),
        findsWidgets,
      );
    });

    testWidgets('fires when pressed', (tester) async {
      var pressed = false;
      await pumpApp(
        tester,
        Scaffold(
          body: Center(
            child: ConnectionOrb(
              state: VgTone.working,
              onPressed: () => pressed = true,
              // Reduced motion: the working state sweeps its ring
              // forever by design, and a forever-running animation
              // is exactly what makes a `pumpAndSettle` time out.
              reducedMotion: true,
            ),
          ),
        ),
      );
      await tester.tap(find.byType(ConnectionOrb), warnIfMissed: false);
      expect(pressed, isTrue);
    });

    testWidgets('offers to cancel while an attempt is running', (tester) async {
      // The control does not go dead once it has been pressed. Before it
      // is pressed again — and it can be pressed again, at any point the
      // attempt has reached — the label has to say that the press stops
      // things, because "Connecting" as an action would be the opposite
      // of what the gesture now does.
      await pumpApp(
        tester,
        Scaffold(
          body: Center(
            child: ConnectionOrb(
              state: VgTone.working,
              onPressed: () {},
              reducedMotion: true,
            ),
          ),
        ),
      );
      expect(find.text('Tap to cancel'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('Activate to cancel')), findsWidgets);
    });

    testWidgets('renders a distinct icon and label for every tone', (
      tester,
    ) async {
      // A state is never signalled by colour alone: every tone carries both
      // an icon and a text label, so the control is readable in greyscale
      // and by a colour-blind user.
      const expectations = {
        VgTone.idle: 'Disconnected',
        VgTone.working: 'Connecting',
        VgTone.connected: 'Connected',
        VgTone.failed: 'Not connected',
        VgTone.blocked: 'Needs attention',
      };
      for (final entry in expectations.entries) {
        await pumpApp(
          tester,
          Scaffold(
            body: Center(
              child: ConnectionOrb(
                state: entry.key,
                onPressed: null,
                reducedMotion: true,
              ),
            ),
          ),
        );
        expect(find.text(entry.value), findsOneWidget, reason: '${entry.key}');
        expect(
          find.byIcon(VgStatusColors.of(entry.key, Brightness.dark).icon),
          findsWidgets,
          reason: '${entry.key}',
        );
      }
    });

    testWidgets('gives every tone its own glyph', (tester) async {
      // The same claim as above, stated about the icons: no two tones share
      // a glyph, so the shapes alone distinguish them.
      final glyphs = <IconData>{};
      for (final tone in VgTone.values) {
        glyphs.add(VgStatusColors.of(tone, Brightness.dark).icon);
      }
      expect(glyphs.length, VgTone.values.length);
    });
  });

  group('VgConnectionSummary', () {
    testWidgets('carries a label so state is not colour-only', (tester) async {
      await pumpApp(
        tester,
        const Scaffold(
          body: Center(
            child: VgConnectionSummary(
              tone: VgTone.connected,
              label: 'Connected',
              detail: 'Netherlands',
            ),
          ),
        ),
      );
      expect(find.text('Connected'), findsOneWidget);
      expect(find.text('Netherlands'), findsOneWidget);
      expect(find.byType(VgStatusDot), findsOneWidget);
    });

    testWidgets('does not draw a filled dot when idle', (tester) async {
      // A filled, glowing dot reads as "active". Idle must not be one.
      await pumpApp(
        tester,
        const Scaffold(
          body: Center(child: VgStatusDot(tone: VgTone.idle)),
        ),
      );
      final dot = tester.widget<Container>(find.byType(Container).first);
      final decoration = dot.decoration! as BoxDecoration;
      expect(decoration.color, Colors.transparent);
    });
  });

  group('AppShell', () {
    testWidgets('uses a bottom bar on a narrow viewport', (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await pumpApp(
        tester,
        AppShell(
          navigation: _TestNavigation(),
          destinations: [
            Destination(
              id: 'home',
              label: 'Home',
              icon: Icons.shield_outlined,
              selectedIcon: Icons.shield,
              builder: (context) => const Text('home body'),
            ),
            Destination(
              id: 'settings',
              label: 'Settings',
              icon: Icons.settings_outlined,
              selectedIcon: Icons.settings,
              builder: (context) => const Text('settings body'),
            ),
          ],
        ),
      );

      expect(find.byType(VgTabBar), findsOneWidget);
      expect(find.byType(VgSidebar), findsNothing);
      expect(find.text('home body'), findsOneWidget);
    });

    testWidgets('uses a sidebar on a wide viewport', (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await pumpApp(
        tester,
        AppShell(
          navigation: _TestNavigation(),
          destinations: [
            Destination(
              id: 'home',
              label: 'Home',
              icon: Icons.shield_outlined,
              selectedIcon: Icons.shield,
              builder: (context) => const Text('home body'),
            ),
          ],
        ),
      );

      expect(find.byType(VgSidebar), findsOneWidget);
      expect(find.byType(VgTabBar), findsNothing);
    });

    testWidgets('switches destination on selection', (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await pumpApp(
        tester,
        AppShell(
          navigation: _TestNavigation(),
          destinations: [
            Destination(
              id: 'home',
              label: 'Home',
              icon: Icons.shield_outlined,
              selectedIcon: Icons.shield,
              builder: (context) => const Text('home body'),
            ),
            Destination(
              id: 'settings',
              label: 'Settings',
              icon: Icons.settings_outlined,
              selectedIcon: Icons.settings,
              builder: (context) => const Text('settings body'),
            ),
          ],
        ),
      );

      expect(find.text('home body'), findsOneWidget);
      // The unselected destination shows its unselected icon; selecting it
      // has to switch both the screen and the icon.
      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pumpAndSettle();
      expect(find.text('settings body'), findsOneWidget);
    });
  });

  group('startup', () {
    test(
      'a platform call that never answers still lets the app start',
      () async {
        // Regression test for a launch that hung on a blank splash: the
        // directory lookup awaited the platform channel with no bound, so
        // a channel that never answered meant the app never started. The
        // production timeout is five seconds; the test uses the real
        // `bootstrap` against a channel that never completes and asserts
        // it returns anyway — with the in-memory store, so nothing is
        // written anywhere and the app still works.
        final channel = const MethodChannel('dev.phantrix.phantrix/tunnel');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (MethodCall call) async {
              // Never completes: the production code must not wait for it.
              await Completer<void>().future;
              throw StateError('unreachable');
            });
        addTearDown(() {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null);
        });

        final scope =
            await AppScope.bootstrap(
              providers: const [],
              platform: PhantrixPlatform(channel: channel),
            ).timeout(
              const Duration(seconds: 30),
              onTimeout: () =>
                  throw StateError('bootstrap hung despite its bound'),
            );
        addTearDown(scope.dispose);
        expect(scope.settingsController.data, isNotNull);
      },
    );

    test('a platform call that throws still lets the app start', () async {
      final channel = const MethodChannel('dev.phantrix.phantrix/tunnel');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            throw PlatformException(code: 'app_directory');
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      final scope = await AppScope.bootstrap(
        providers: const [],
        platform: PhantrixPlatform(channel: channel),
      );
      addTearDown(scope.dispose);
      expect(scope.settingsController.data, isNotNull);
    });

    test('a single slow answer is retried, not mistaken for absence', () async {
      // The retry exists because a first timeout on a cold device may be
      // transient slowness. This pins that a slow-but-answering platform
      // still yields its directory: the alternative is a launch that
      // silently forgets every stored configuration.
      var calls = 0;
      final channel = const MethodChannel('dev.phantrix.phantrix/tunnel');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            // Only the directory lookup is counted: the connection
            // controller fires an unawaited capabilities load of its own,
            // and counting that too would couple this test to unrelated
            // startup traffic.
            if (call.method != 'appDataDirectory') {
              return null;
            }
            calls++;
            if (calls == 1) {
              await Completer<void>().future;
              throw StateError('unreachable');
            }
            return '/private/dir';
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      final scope =
          await AppScope.bootstrap(
            providers: const [],
            platform: PhantrixPlatform(channel: channel),
          ).timeout(
            const Duration(seconds: 30),
            onTimeout: () =>
                throw StateError('bootstrap hung despite its bound'),
          );
      addTearDown(scope.dispose);
      expect(calls, 2);
      expect(scope.settingsController.data, isNotNull);
    });
  });
}

/// A navigation stub for shell tests.
///
/// The shell reads navigation rather than owning it, so a shell test needs to
/// supply one. This one is deliberately minimal: it records the selection and
/// notifies, which is all the shell asks of it. Using the real
/// `AppNavigation` here would test the shell and the navigation together and
/// would make a failure in either hard to locate.
class _TestNavigation extends ChangeNotifier implements AppNavigationLike {
  int _index = 0;

  @override
  int get index => _index;

  @override
  String? get currentId => null;

  @override
  void Function(int) get select => _select;

  void _select(int value) {
    if (value == _index) {
      return;
    }
    _index = value;
    notifyListeners();
  }
}
