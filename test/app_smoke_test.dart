import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';


import 'package:phantrix_core/phantrix_core.dart';

import 'package:phantrix/discovery/discovery_controller.dart';
import 'package:phantrix/settings/settings_controller.dart';
import 'package:phantrix/ui/components/navigation.dart';
import 'package:phantrix/phantrix_app.dart';

/// A fetcher that refuses everything, so a smoke test can never open a
/// socket. The discovery layer must cope, which is itself part of what these
/// tests assert.
class _OfflineFetcher implements HttpFetcher {
	@override
	int get maxBodyBytes => 1024;

	@override
	Future<String> get(Uri url) async =>
			throw const AppError(
				group: ErrorGroup.network,
				code: 'http.unreachable',
				message: 'Could not reach the server list. Check your connection.',
			);
}

/// Builds a scope that never touches the network or the disk.
AppScope offlineScope({required bool onboarded}) {
	final settings = SettingsController(
		SettingsController().data.copyWith(
			privacyNoticeAccepted: onboarded,
			onboardingComplete: onboarded,
		),
	);
	return AppScope.inMemory(
		settings: settings,
		providers: buildProviders(
			enabled: const {ProviderId.vpnGate},
			fetcher: _OfflineFetcher(),
		),
	);
}

/// Smoke tests that render the real app tree.
///
/// These exist because `flutter analyze` cannot see a layout overflow and a
/// per-widget test cannot see that a whole screen does not fit a phone.
/// Rendering the entire app at several viewport sizes is the cheapest way to
/// catch both.
///
/// ## What these assert, and what they deliberately do not
///
/// They assert *presence and reachability* — the connect control exists, the
/// screens can be navigated to, nothing overflows, a failure is explained.
/// They do not assert exact copy: a wording change is not a regression, and a
/// test that fails on it would get deleted rather than fixed, which is the
/// worst outcome a test can have.
/// The primary connect control.
///
/// Found by its accessible name rather than by a button label, because the
/// control is a large tappable orb rather than a text button, and because the
/// accessible name is what a screen reader announces — so asserting on it is
/// asserting on something a user actually experiences.
Finder get connectControl => find.byWidgetPredicate(
	(Widget widget) =>
		widget is Semantics &&
		widget.properties.label != null &&
		widget.properties.label!.contains('Activate to connect') &&
		widget.properties.button == true,
);

/// Taps a destination in whichever navigation surface this window width
/// produced.
///
/// The app uses a sidebar on a desktop window and a bottom bar on a phone, so
/// "tap Settings" has to mean "tap it where it is". Searching for the label
/// anywhere would also match the *title* of the screen once it is showing,
/// which is a control that cannot be tapped; scoping the search to the
/// navigation surface is what keeps this unambiguous.
Future<void> goTo(WidgetTester tester, String label) async {
	final inSidebar = find.descendant(
		of: find.byType(VgSidebar),
		matching: find.text(label),
	);
	final inBar = find.descendant(
		of: find.byType(VgTabBar),
		matching: find.text(label),
	);
	final target = inSidebar.evaluate().isNotEmpty ? inSidebar.first : inBar.first;
	expect(target, findsOneWidget, reason: 'no navigation surface offers "$label"');
	await tester.tap(target);
	await tester.pumpAndSettle();
}

/// Scrolls the current screen until [label] is on screen.
///
/// Settings is a lazy list, so an entry below the fold has no widget at all
/// until something scrolls it into existence. Looking for it first would fail
/// on "not found" and say nothing about whether the entry works.
Future<void> _scrollTo(WidgetTester tester, String label, {double step = 120}) async {
	for (var attempt = 0; attempt < 12; attempt++) {
		final target = find.text(label);
		if (target.evaluate().isNotEmpty) {
			await tester.ensureVisible(target.first);
			await tester.pumpAndSettle();
			return;
		}
		await tester.drag(find.byType(Scrollable).last, Offset(0, -step));
		await tester.pumpAndSettle();
	}
	fail('$label never came into view; the settings screen may have grown an '
		'unreachable entry');
}

void main() {
	Future<void> pumpApp(
		WidgetTester tester, {
		Size size = const Size(400, 850),
		bool onboarded = true,
	}) async {
		tester.view.physicalSize = size;
		tester.view.devicePixelRatio = 1;
		addTearDown(tester.view.reset);

		final scope = offlineScope(onboarded: onboarded);
		addTearDown(scope.dispose);

		await tester.pumpWidget(PhantrixApp(scope: scope));
		await tester.pump();
	}

	group('PhantrixApp', () {
		testWidgets('first run shows the privacy notice, not the dashboard',
			(tester) async {
			await pumpApp(tester, onboarded: false);
			expect(find.text('Private, simple, no account required.'), findsOneWidget);
			expect(find.text('I understand. Continue.'), findsOneWidget);
			// The connect control must not exist yet: there is nothing behind
			// the notice to connect to.
			expect(connectControl, findsNothing);
		});

		testWidgets('the dashboard renders on a phone without overflow',
			(tester) async {
			await pumpApp(tester);
			expect(connectControl, findsOneWidget);
			// Disconnected has to be legible as words as well as colour.
			expect(find.text('Disconnected'), findsOneWidget);
			// The two labelled actions the screen offers. Both are checked because
			// an unlabelled icon is invisible to a screen reader and guesswork to
			// everyone else.
			expect(find.text('Choose a location'), findsOneWidget);
			expect(find.text('Import'), findsOneWidget);
			// The row under the orb says where a connection would go. With no
			// country remembered it is the saved "automatic" preference, and
			// it must be words, not just a colour or an icon.
			expect(find.textContaining('Automatic'), findsOneWidget);
		});

		testWidgets('the dashboard renders on a desktop viewport', (tester) async {
			await pumpApp(tester, size: const Size(1400, 900));
			expect(connectControl, findsOneWidget);
			// The two labelled actions the screen offers. Both are checked because
			// an unlabelled icon is invisible to a screen reader and guesswork to
			// everyone else.
			expect(find.text('Choose a location'), findsOneWidget);
			expect(find.text('Import'), findsOneWidget);
		});

		testWidgets('every destination builds without overflow', (tester) async {
			await pumpApp(tester);
			for (final label in ['Servers', 'Settings']) {
				await goTo(tester, label);
				expect(
					tester.takeException(),
					isNull,
					reason: 'overflow or error on the $label screen',
				);
			}

			// Diagnostics and Privacy are deliberately absent from the phone
			// bottom bar — the app is three tabs (Home, Servers, Settings) — so
			// this also checks that they are still reachable from Settings. A
			// trimmed bar that strands two screens would pass a loop over the
			// bar alone.
			//
			// Settings is a lazy list, so the entries below the fold are not
			// built yet and have to be scrolled to rather than merely looked for.
			await _scrollTo(tester, 'Diagnostics');
			await tester.tap(find.text('Diagnostics'));
			await tester.pumpAndSettle();
			expect(tester.takeException(), isNull);
			await goTo(tester, 'Settings');
			await _scrollTo(tester, 'Privacy notice');
			await tester.tap(find.text('Privacy notice'));
			await tester.pumpAndSettle();
			expect(tester.takeException(), isNull);
		});

		testWidgets('the bottom bar is the three primary tabs', (tester) async {
			await pumpApp(tester);
			// The app is a three-tab product. Adding a fourth primary tab is a
			// decision, not an oversight, so this pins the set by name rather
			// than merely the count — it keeps holding when a secondary screen
			// is moved but fails if a secondary destination is promoted to a tab.
			final labels = tester
				.widget<VgTabBar>(find.byType(VgTabBar))
				.items
				.map((i) => i.label)
				.toList();
			expect(
				labels,
				equals(['Home', 'Servers', 'Settings']),
				reason: 'only Home, Servers and Settings are primary tabs; found $labels',
			);
		});

		testWidgets('the configurations screen explains itself when empty',
			(tester) async {
			await pumpApp(tester);
			// Configs is a secondary destination now, opened over the tabs from
			// Settings rather than as a fourth tab. It must still build and be
			// reachable.
			await goTo(tester, 'Settings');
			await _scrollTo(tester, 'Configurations');
			await tester.tap(find.text('Configurations'));
			await tester.pumpAndSettle();

			// An empty list with no explanation reads as a bug. This screen must
			// say what is missing and what to do about it.
			expect(find.text('No configurations yet'), findsOneWidget);
			expect(find.text('Import a configuration'), findsOneWidget);
			expect(find.textContaining('Nothing is uploaded'), findsOneWidget);
		});

		testWidgets('the licences page is reachable from Settings', (tester) async {
			await pumpApp(tester);
			await goTo(tester, 'Settings');

			// The entry is below the fold in the phone-sized settings list, so
			// it is scrolled to first; an entry that cannot be reached does not
			// exist as far as a user is concerned.
			await _scrollTo(tester, 'About, licenses and credits', step: 300);
			await tester.tap(find.text('About, licenses and credits'));
			await tester.pumpAndSettle();

			// The page renders from the generated inventory: a real version,
			// a real source URL and the full GPLv3 text, one tap away.
			expect(find.text('LICENSES & CREDITS'), findsOneWidget);
			expect(find.text('phantrix 1.0.0+1'), findsOneWidget);
			expect(tester.takeException(), isNull);
		});

		testWidgets('a large accessibility text scale still fits', (tester) async {
			tester.view.physicalSize = const Size(400, 850);
			tester.view.devicePixelRatio = 1;
			addTearDown(tester.view.reset);

			final scope = offlineScope(onboarded: true);
			addTearDown(scope.dispose);

			await tester.pumpWidget(
				MediaQuery(
					data: const MediaQueryData(textScaler: TextScaler.linear(2.0)),
					child: PhantrixApp(scope: scope),
				),
			);
			await tester.pumpAndSettle();
			expect(tester.takeException(), isNull);
		});

		testWidgets('an unreachable server source is reported, not hidden',
			(tester) async {
			await pumpApp(tester);
			await goTo(tester, 'Servers');
			// Let the provider failure land.
			await tester.pumpAndSettle();

			// The screen must say the list could not be loaded rather than
			// showing an empty list that looks like a bug — and it must offer
			// the one action that could change that.
			expect(find.text('The server list could not be loaded.'), findsOneWidget);
			expect(find.widgetWithText(TextButton, 'Retry'), findsOneWidget);
		});

		testWidgets('no country is invented when discovery fails', (tester) async {
			await pumpApp(tester);
			await goTo(tester, 'Servers');
			await tester.pumpAndSettle();

			// The old build hardcoded fifteen countries with invented server
			// counts and latencies. None of those may appear.
			for (final code in ['JP', 'DE', 'US', 'NL', 'SG', 'GB', 'FR', 'CA']) {
				expect(find.text(code), findsNothing, reason: '$code was fabricated');
			}
		});

		testWidgets('pressing Connect with an empty directory says why, and does not '
			'claim success', (tester) async {
			await pumpApp(tester);
			await tester.tap(connectControl);
			await tester.pumpAndSettle();

			// The user must be told there is nothing to connect to, in plain
			// words, and the app must not pretend a tunnel is coming up. The
			// explanation lives in the error card only — the status line shows
			// the state label instead, so printing the reason twice would read
			// as two separate problems.
			expect(
				find.textContaining('No server list is available yet'),
				findsOneWidget,
				reason: 'the reason belongs in the error card, not the status line',
			);
			// Nothing may claim success. This is the whole point of the test, so
			// it is checked against every element on screen rather than one.
			expect(find.text('Connected'), findsNothing);
			expect(find.text('Tunnel established'), findsNothing);
			expect(find.textContaining('Connecting'), findsNothing);
			// The orb must not read as connected either — it is the largest
			// element on the screen and the first thing anyone reads.
			expect(find.text('Connected'), findsNothing);
			// The user must not be stranded: the control is still on screen and
			// enabled, and there is a route to the fix.
			expect(connectControl, findsOneWidget);
			expect(
				find.textContaining('Choose a location'),
				findsWidgets,
				reason: 'there must be an action that leads to the fix',
			);
			expect(tester.takeException(), isNull);
		});
	});

	group('the dashboard notice follows what the build can do', () {
		// The notice claims this build "connects through WireGuard only"
		// and asks for a WireGuard file. It is a claim about the build, so
		// it must follow the capability the platform reports — yet it was
		// shown unconditionally, telling users to import a file to do the
		// very thing the button above them already does, on builds whose
		// OpenVPN engine works. Both directions are pinned: a capable
		// build is not told it is incapable, an incapable one still is.
		const channel = MethodChannel('dev.phantrix.phantrix/tunnel');
		var openVpn = false;

		setUp(() {
			TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
				.setMockMethodCallHandler(channel, (call) async {
					if (call.method != 'capabilities') {
						return null;
					}
					return <String, Object?>{
						'platform': 'test',
						'killSwitch': false,
						'ipv6Block': false,
						'vpnDns': false,
						'perApp': false,
						'lanBypass': false,
						'alwaysOn': false,
						'tray': false,
						'bootStart': false,
						'openVpn': openVpn,
						'limitations': <String, String>{},
					};
				});
		});

		tearDown(() {
			TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
				.setMockMethodCallHandler(channel, null);
		});

		testWidgets('a build that can start OpenVPN is not told it cannot',
			(tester) async {
			openVpn = true;
			await pumpApp(tester);
			// The capability is read over the channel after first paint,
			// so the assertion waits for the stream to settle rather than
			// judging the frame before the answer arrived.
			await tester.pumpAndSettle();
			expect(
				find.text('The built-in public relays need OpenVPN support'),
				findsNothing,
			);
			expect(
				find.textContaining('connects through WireGuard only'),
				findsNothing,
			);
			expect(tester.takeException(), isNull);
		});

		testWidgets('a build that cannot start OpenVPN is still told so',
			(tester) async {
			openVpn = false;
			await pumpApp(tester);
			await tester.pumpAndSettle();
			expect(
				find.text('The built-in public relays need OpenVPN support'),
				findsOneWidget,
			);
			expect(tester.takeException(), isNull);
		});
	});
}
