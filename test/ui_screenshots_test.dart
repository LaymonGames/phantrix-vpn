import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:phantrix_core/phantrix_core.dart';

import 'package:phantrix/discovery/discovery_controller.dart';
import 'package:phantrix/settings/settings_controller.dart';
import 'package:phantrix/theme/app_theme.dart';
import 'package:phantrix/theme/tokens.dart';
import 'package:phantrix/ui/components/connection_orb.dart';
import 'package:phantrix/ui/components/navigation.dart';
import 'package:phantrix/ui/components/status_style.dart';
import 'package:phantrix/app/app_scope.dart';
import 'package:phantrix/phantrix_app.dart';

/// Renders the real application at several sizes and writes the result to
/// `docs/evidence/ui/`.
///
/// ## Why this exists
///
/// `flutter analyze` cannot see a layout overflow, a widget test cannot judge
/// whether a screen looks *designed*, and a successful build says nothing about
/// either. Reviewing a user interface means looking at it.
///
/// Flutter's test renderer draws into an offscreen surface, so this produces a
/// real rendering of the real widget tree with no display attached, and it
/// fails the run if anything overflows — which makes it a design review and a
/// layout regression test in one.
///
/// The system fonts are loaded explicitly because the test environment
/// otherwise substitutes a placeholder face whose glyphs are solid rectangles,
/// which would make every screenshot useless for judging typography.
///
/// Regenerate with:
///
///     flutter test test/ui_screenshots_test.dart --update-goldens
void main() {
  setUpAll(_loadSystemFonts);

  // The platform bridge is absent in a host test, and the event channel
  // throws `MissingPluginException` when it tries to listen. That is
  // reported as an unhandled asynchronous error, which fails the test for a
  // reason that has nothing to do with what is being photographed. Standing
  // in a no-op bridge keeps the exception out of the way without inventing a
  // connection: the tunnel is genuinely not running here, and the screenshot
  // should say "disconnected", not pretend otherwise.
  setUpAll(() {
    const messengerChannels = <String, MethodChannel>{
      'dev.phantrix.phantrix/tunnel': MethodChannel(
        'dev.phantrix.phantrix/tunnel',
      ),
    };
    for (final channel in messengerChannels.values) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            return switch (call.method) {
              'capabilities' => <String, Object?>{
                'platform': 'screenshot',
                'killSwitch': false,
                'ipv6Block': true,
                'vpnDns': true,
                'perApp': false,
                'lanBypass': true,
                'alwaysOn': false,
                'tray': false,
                'bootStart': false,
                'limitations': <String, String>{},
              },
              'requestPermission' => true,
              'appDataDirectory' => null,
              _ => null,
            };
          });
    }

    const events = MethodChannel('dev.phantrix.phantrix/tunnelEvents');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(events, (MethodCall call) async => null);
  });

  group('responsive layout', () {
    // A regression test, not a screenshot. The rail and the bottom bar
    // exist for genuinely different window shapes, and the failure mode —
    // a phone bar stretched across a desktop window — looks plausible
    // enough that it would survive a casual look.
    testWidgets('a desktop window gets a navigation rail', (tester) async {
      await _boot(tester, size: const Size(1440, 900));
      expect(find.byType(VgSidebar), findsOneWidget);
      expect(find.byType(VgTabBar), findsNothing);
    });

    testWidgets('a phone window gets a bottom bar', (tester) async {
      await _boot(tester, size: const Size(412, 892));
      expect(find.byType(VgSidebar), findsNothing);
      expect(find.byType(VgTabBar), findsOneWidget);
    });

    testWidgets('content is column-capped rather than stretched', (
      tester,
    ) async {
      await _boot(tester, size: const Size(2560, 1400));
      // Every scrolling region, not just the first: measuring one and
      // hoping it is the right one is how a cap test passes on the wrong
      // widget.
      final widths = <double>[];
      for (final element in find.byType(Scrollable).evaluate()) {
        final box = element.renderObject;
        widths.add(box is RenderBox ? box.size.width : -1);
      }
      expect(widths, isNotEmpty);
      // The dashboard is the widest thing the app draws — it is a grid of
      // panels, not a measure of prose — so it sets the bound. A
      // one-column screen is capped tighter still, and that tighter cap
      // is asserted in its own test below.
      expect(
        widths.reduce((a, b) => a > b ? a : b),
        lessThanOrEqualTo(VgSpace.maxDashboardWidth + 8),
        reason:
            'a 2560px window must not stretch a 1160px dashboard; '
            'measured widths were $widths',
      );
    });

    testWidgets('a reading column stays a readable measure at 2560px', (
      tester,
    ) async {
      await _boot(
        tester,
        size: const Size(2560, 1400),
        destination: 'Settings',
      );
      final widths = <double>[];
      for (final element in find.byType(Scrollable).evaluate()) {
        final box = element.renderObject;
        widths.add(box is RenderBox ? box.size.width : -1);
      }
      expect(widths, isNotEmpty);
      // Settings is one column of settings. On a 4K display it must stop
      // being a column of text, or a toggle ends up a metre from the label
      // that explains it.
      expect(
        widths.reduce((a, b) => a > b ? a : b),
        lessThanOrEqualTo(VgSpace.maxContentWidth + 8),
        reason: 'measured widths were $widths',
      );
    });
  });

  group('the real application, rendered', () {
    testWidgets('onboarding at phone size', (tester) async {
      await _boot(tester, size: const Size(412, 892), onboarded: false);
      await _capture(tester, '01-onboarding-phone');
    });

    testWidgets('dashboard, disconnected, at phone size', (tester) async {
      await _boot(tester, size: const Size(412, 892));
      await _capture(tester, '02-dashboard-phone');
    });

    testWidgets('dashboard at desktop size', (tester) async {
      await _boot(tester, size: const Size(1440, 900));
      await _capture(tester, '03-dashboard-desktop');
    });

    testWidgets('dashboard at a narrow window', (tester) async {
      await _boot(tester, size: const Size(360, 640));
      await _capture(tester, '04-dashboard-narrow');
    });

    testWidgets('servers, unreachable source', (tester) async {
      await _boot(tester, size: const Size(412, 892), destination: 'Servers');
      await _capture(tester, '05-servers');
    });

    testWidgets('settings at desktop size', (tester) async {
      await _boot(tester, size: const Size(1440, 900), destination: 'Settings');
      await _capture(tester, '06-settings-desktop');
    });

    testWidgets('dashboard at a large accessibility text scale', (
      tester,
    ) async {
      await _boot(tester, size: const Size(412, 892), textScale: 1.6);
      await _capture(tester, '07-dashboard-large-text');
    });

    testWidgets('dashboard in the light theme', (tester) async {
      await _boot(tester, size: const Size(412, 892), theme: 'light');
      await _capture(tester, '08-dashboard-light');
    });
  });

  group('connection states, rendered', () {
    // Every other screenshot in this file shows the app *disconnected*,
    // because that is the only state a host test can honestly reach: the
    // state machine will not say "connected" without a real handshake and a
    // changed address, and inventing one here would file a picture of a
    // screen the app cannot actually show.
    //
    // The control itself takes its state as a parameter, so the other four
    // states *can* be photographed honestly — and they should be, because
    // "the state is legible" is a visual claim, and a screenshot of one
    // state cannot support it. Laid out side by side on purpose: the test
    // is whether the five are told apart at a glance.
    testWidgets('all five control states, side by side', (tester) async {
      tester.view.physicalSize = const Size(980, 300);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        RepaintBoundary(
          key: _captureKey,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: AppTheme.dark(animationLevel: 'none'),
            home: Scaffold(
              body: Center(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    for (final tone in VgTone.values)
                      ConnectionOrb(
                        // Reduced motion: the working state
                        // sweeps its ring forever, and a
                        // screenshot must be of a settled
                        // layout rather than of whatever
                        // frame it happened to catch.
                        reducedMotion: true,
                        state: tone,
                        onPressed: () {},
                        size: 168,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await _capture(tester, '09-control-states');
    });
  });
}

/// Boots the real app at [size] and settles it.
///
/// The viewport is set once, before the first frame, and never changed
/// afterwards: resizing after the tree is built leaves a stale layout, which
/// produces a screenshot of a screen that no device would actually show.
Future<void> _boot(
  WidgetTester tester, {
  required Size size,
  bool onboarded = true,
  String? destination,
  String theme = 'dark',
  double textScale = 1.0,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final settings = SettingsController(
    AppSettings.defaults.copyWith(
      privacyNoticeAccepted: onboarded,
      onboardingComplete: onboarded,
      themeMode: theme,
    ),
  );
  final scope = AppScope.inMemory(
    settings: settings,
    providers: buildProviders(
      enabled: const {ProviderId.vpnGate},
      fetcher: _UnreachableFetcher(),
    ),
  );
  addTearDown(scope.dispose);

  // The size must be carried on the MediaQuery as well as on the view.
  // `MaterialApp` inherits an ancestor's MediaQuery when there is one, so a
  // wrapper carrying only a text scaler would report a viewport of zero and
  // every responsive decision inside the app would be made against it.
  await tester.pumpWidget(
    RepaintBoundary(
      key: _captureKey,
      child: MediaQuery(
        data: MediaQueryData(
          size: size,
          devicePixelRatio: 1.0,
          textScaler: TextScaler.linear(textScale),
        ),
        child: PhantrixApp(scope: scope),
      ),
    ),
  );
  await tester.pump();
  if (destination != null) {
    // The two navigation surfaces are custom widgets rather than
    // Material's `NavigationRail`/`NavigationBar`, so neither can be searched
    // for by configuration-object type. Scoping the search to the surface
    // that this window width produced is what finds the label to tap —
    // and scoping it matters, because once a screen is showing, the same
    // word is also the screen's title in the header, which is not a
    // control.
    final inSidebar = find.descendant(
      of: find.byType(VgSidebar),
      matching: find.text(destination),
    );
    final inBar = find.descendant(
      of: find.byType(VgTabBar),
      matching: find.text(destination),
    );
    final target = inSidebar.evaluate().isNotEmpty
        ? inSidebar.first
        : inBar.first;
    expect(
      target,
      findsOneWidget,
      reason: 'no navigation surface offers $destination',
    );
    await tester.tap(target);
    await tester.pump();
  }
  // Long enough for the entrance transitions to finish, so the screenshot
  // catches a settled layout rather than a half-finished fade.
  await tester.pump(const Duration(milliseconds: 700));
  await tester.pumpAndSettle();

  // A screenshot of a broken layout is worse than no screenshot: it would be
  // filed as evidence that the design is finished.
  expect(
    tester.takeException(),
    isNull,
    reason: 'something overflowed or threw while building the app at $size',
  );
}

/// Writes the settled app to `docs/evidence/ui/<name>.png`.
///
/// Deliberately a write, not a golden comparison. A golden compares against a
/// committed PNG, which means it fails on any machine whose font rasteriser
/// differs by a subpixel — so the test would be red for reasons that have
/// nothing to do with the code, and the tempting response would be to stop
/// looking at the pictures. Writing instead means the evidence is refreshed
/// every run on every machine, and the assertions that actually matter (no
/// overflow, correct responsive surface) stay separate and stay strict.
Future<void> _capture(WidgetTester tester, String name) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_captureKey),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (data == null) {
      throw StateError('the renderer produced no PNG for $name');
    }
    final file = File('docs/evidence/ui/$name.png')
      ..createSync(recursive: true);
    file.writeAsBytesSync(data.buffer.asUint8List());
  });
}

/// The boundary the screenshots are taken from.
///
/// Explicitly introduced rather than searching for whatever repaint boundary
/// happens to be first in the tree, because "first in the tree" changes when
/// an unrelated widget gains one and the screenshots silently start cropping.
final GlobalKey _captureKey = GlobalKey();

/// A fetcher that refuses everything, so a screenshot run can never open a
/// socket and never depends on the network being up.
///
/// A screenshot of what a user with no connection sees is more honest than one
/// showing an invented happy path.
class _UnreachableFetcher implements HttpFetcher {
  @override
  int get maxBodyBytes => 1024;

  @override
  Future<String> get(Uri url) async => throw const AppError(
    group: ErrorGroup.network,
    code: 'http.unreachable',
    message: 'Could not reach the server list. Check your connection.',
  );
}

/// Loads the host's real fonts into the test renderer.
///
/// Tries a few known filenames and loads whichever exist, so the file works on
/// a machine with different fonts installed. If none are found the
/// screenshots still render, just with the placeholder face — which is why the
/// output is worth looking at rather than assuming.
Future<void> _loadSystemFonts() async {
  // Material's icon font first. Without it every icon in every screenshot is
  // a filled rectangle, which makes the whole set useless for judging
  // whether the interface actually looks designed.
  await _loadFont('MaterialIcons', const [
    r'C:\FlutterSDK\bin\cache\artifacts\material_fonts\MaterialIcons-Regular.otf',
    '/usr/share/fonts/truetype/material/MaterialIcons-Regular.otf',
  ]);

  const candidates = <String, List<String>>{
    'Inter': ['segoeui.ttf', 'Inter-Regular.ttf', 'Roboto-Regular.ttf'],
    'Segoe UI': ['segoeui.ttf'],
    'system-ui': ['segoeui.ttf', 'arial.ttf'],
    'Roboto': ['Roboto-Regular.ttf', 'arial.ttf'],
    'monospace': ['consola.ttf', 'DejaVuSansMono.ttf'],
  };
  const roots = [
    r'C:\Windows\Fonts',
    '/System/Library/Fonts',
    '/usr/share/fonts/truetype',
  ];

  // Loaded through the same helper so a missing file on one machine does
  // not silently produce a set of unreadable screenshots.
  var loadedAny = false;
  for (final entry in candidates.entries) {
    final loaded = await _loadFont(entry.key, [
      for (final name in entry.value)
        for (final root in roots) '$root${Platform.pathSeparator}$name',
    ]);
    loadedAny = loadedAny || loaded;
  }
  if (!loadedAny) {
    // ignore: avoid_print
    print(
      'ui_screenshots: no system font was found, so the screenshots use '
      'the placeholder face and cannot be used to judge typography.',
    );
  }
}

/// Loads [family] from the first path in [candidates] that exists.
///
/// Returns whether anything was loaded. The Flutter SDK path is only correct
/// on a machine where the SDK sits at that exact location, which is why every
/// candidate has an alternative: a developer elsewhere should still get
/// readable screenshots rather than boxes.
Future<bool> _loadFont(String family, List<String> candidates) async {
  for (final path in candidates) {
    final file = File(path);
    if (!file.existsSync()) {
      continue;
    }
    try {
      final bytes = await file.readAsBytes();
      await (FontLoader(
        family,
      )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
      return true;
    } on Object {
      // A font that will not load is skipped rather than failing the
      // run: the screenshot is still worth having without it.
    }
  }
  return false;
}
