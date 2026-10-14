import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:phantrix_core/phantrix_core.dart';

import 'package:phantrix/ui/screens/locations_screen.dart';

/// The Locations screen carries a notice claiming this build "connects
/// through WireGuard only", shown whenever the feed offers OpenVPN servers.
/// That is the exact case in which the claim is most wrong: a build that
/// can start OpenVPN can use every server in that list as it is, and the
/// notice was telling users to import a file first — on builds whose
/// engine had been proven to work.
///
/// The screen is a pure function of the inputs it is handed, so both
/// directions of the condition are pinned here with no networking and no
/// platform channels: the claim appears when the build is genuinely
/// incapable, and is absent when the platform reports an engine.
void main() {
	const noticeFragment = 'connects through WireGuard only';

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
				byCountry: {'JP': [relay()]},
				lastFetchedAt: DateTime(2026, 10, 10),
				providerErrors: const {},
			);

	Future<void> pumpLocations(
		WidgetTester tester, {
		required bool openVpnSupported,
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
						onManageConfigurations: () {},
					),
				),
			),
		);
		await tester.pumpAndSettle();
	}

	testWidgets('a build that can start OpenVPN is not told it cannot',
		(tester) async {
		await pumpLocations(tester, openVpnSupported: true);

		// Neither the claim nor the remedy it offers may appear: the
		// servers on this screen are usable as they are.
		expect(find.textContaining(noticeFragment), findsNothing);
		expect(find.text('Import WireGuard config'), findsNothing);
		// The list itself must still be there — the fix removes a claim,
		// not the directory.
		expect(find.textContaining('Japan'), findsWidgets);
		expect(tester.takeException(), isNull);
	});

	testWidgets(
		'a build that cannot start OpenVPN is still told so, with the '
		'alternative offered',
		(tester) async {
		await pumpLocations(tester, openVpnSupported: false);

		expect(find.textContaining(noticeFragment), findsOneWidget);
		expect(find.text('Import WireGuard config'), findsOneWidget);
		expect(tester.takeException(), isNull);
	});
}
