import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:phantrix_core/phantrix_core.dart';

import 'package:phantrix/ui/screens/locations_screen.dart';

/// The Locations screen carries one notice: the public feed speaks OpenVPN,
/// so a build with no engine for it can use none of the servers on screen.
/// The notice must appear in exactly that case and never otherwise — a
/// capable build being told it cannot use the list it is looking at is the
/// failure this pins against.
///
/// The screen is a pure function of the inputs it is handed, so both
/// directions of the condition are pinned here with no networking and no
/// platform channels.
void main() {
  const noticeFragment = 'no OpenVPN engine';

  VpnServer relay() => const VpnServer(
    id: 'relay-1',
    hostname: 'public-relay-001.example.net',
    hostAddress: '203.0.113.10',
    port: 443,
    protocol: ProtocolKind.openVpn,
    trustLevel: TrustLevel.publicRelay,
    countryCode: 'JP',
    providerId: 'vpngate',
  );

  DirectorySnapshot feed() => DirectorySnapshot(
    servers: [relay()],
    state: DirectoryState.fresh,
    byCountry: {
      'JP': [relay()],
    },
    lastFetchedAt: DateTime(2026, 10, 10),
    providerErrors: const {},
  );

  Future<void> pumpLocations(
    WidgetTester tester, {
    required bool openVpnSupported,
    Future<void> Function()? onRefresh,
    bool isRefreshing = false,
  }) async {
    tester.view.physicalSize = const Size(400, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LocationsScreen(
            onCountrySelected: (_) {},
            snapshot: feed(),
            openVpnSupported: openVpnSupported,
            onRefresh: onRefresh,
            isRefreshing: isRefreshing,
          ),
        ),
      ),
    );
    if (isRefreshing) {
      // A spinner never settles, so the harness must not wait for one.
      await tester.pump();
    } else {
      await tester.pumpAndSettle();
    }
  }

  testWidgets('a build that can start OpenVPN is not told it cannot', (
    tester,
  ) async {
    await pumpLocations(tester, openVpnSupported: true);

    expect(find.textContaining(noticeFragment), findsNothing);
    // The list itself must still be there — the notice is absent, not
    // the directory.
    expect(find.textContaining('Japan'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a build with no OpenVPN engine says so', (tester) async {
    await pumpLocations(tester, openVpnSupported: false);

    expect(find.textContaining(noticeFragment), findsOneWidget);
    expect(find.textContaining('Japan'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the refresh button above the list refetches the servers', (
    tester,
  ) async {
    var refreshes = 0;
    await pumpLocations(
      tester,
      openVpnSupported: true,
      onRefresh: () async => refreshes++,
    );

    final refresh = find.byTooltip('Refresh');
    expect(refresh, findsOneWidget);
    await tester.tap(refresh);
    await tester.pump();

    expect(refreshes, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the refresh button reports and blocks a refresh in flight', (
    tester,
  ) async {
    await pumpLocations(
      tester,
      openVpnSupported: true,
      onRefresh: () async {},
      isRefreshing: true,
    );

    // One spinner in the button, one in the directory banner.
    expect(find.byType(CircularProgressIndicator), findsNWidgets(2));
    final button = tester.widget<IconButton>(
      find.ancestor(
        of: find.descendant(
          of: find.byType(IconButton),
          matching: find.byType(CircularProgressIndicator),
        ),
        matching: find.byType(IconButton),
      ),
    );
    expect(button.onPressed, isNull);
    expect(tester.takeException(), isNull);
  });
}
