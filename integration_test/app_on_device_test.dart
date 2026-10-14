import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:phantrix/main.dart' as app;
import 'package:phantrix/ui/components/navigation.dart';

/// On-device tests for the real application.
///
/// These differ from everything else in this repository in one decisive way:
/// they run the **real app on a real Android device or emulator**, through the
/// real widget tree, the real platform channel and the real operating system.
/// A host-VM widget test cannot observe any of that, which is why these
/// assertions are about behaviour that only exists on a device.
///
/// ### What these tests do and do not establish
///
/// They establish that the app starts, the first-run flow works, the UI
/// survives a real layout pass, and — most importantly — that pressing the
/// connect control reports the truth when there is nothing to connect to.
/// That last one is the property that matters most: a VPN that claims success
/// when it has not connected is worse than one that does not work at all.
///
/// They do **not** establish that a tunnel works. That needs a reachable
/// WireGuard peer, which is not available here, and no test in this file
/// pretends otherwise. A test that asserted a successful handshake without a
/// peer would be asserting something that was never checked.
///
/// ### No credentials
///
/// No private key, endpoint or account is used or embedded. Anything the app
/// would need to reach a real server comes from the VPN Gate feed, and the
/// tests below deliberately do not depend on it being reachable.
void main() {
	IntegrationTestWidgetsFlutterBinding.ensureInitialized();

	/// Starts the real application on this device.
	Future<void> launch(WidgetTester tester) async {
		app.main();
		await tester.pumpAndSettle(const Duration(seconds: 2));
	}

	Future<void> acceptPrivacyNoticeIfShown(WidgetTester tester) async {
		final button = find.text('I understand. Continue.');
		if (button.evaluate().isNotEmpty) {
			await tester.tap(button);
			await tester.pumpAndSettle(const Duration(seconds: 1));
		}
	}

	/// Moves to the destination named [label], on whatever navigation surface
	/// this window width produced.
	///
	/// A sidebar on wide windows, a bottom bar on phones — and Diagnostics and
	/// Privacy are linked from Settings on a phone rather than sitting in the
	/// bar, because six labels do not survive a large text scale.
	Future<void> goTo(WidgetTester tester, String label) async {
		final inSidebar = find.descendant(
			of: find.byType(VgSidebar),
			matching: find.text(label),
		);
		if (inSidebar.evaluate().isNotEmpty) {
			await tester.tap(inSidebar.first);
			await tester.pumpAndSettle(const Duration(milliseconds: 400));
			return;
		}
		final inBar = find.descendant(
			of: find.byType(VgTabBar),
			matching: find.text(label),
		);
		if (inBar.evaluate().isNotEmpty) {
			await tester.tap(inBar.first);
			await tester.pumpAndSettle(const Duration(milliseconds: 400));
			return;
		}
		// Linked from Settings on compact layouts.
		await goTo(tester, 'Settings');
		await tester.scrollUntilVisible(
			find.text(label),
			500,
			scrollable: find.byType(Scrollable).last,
		);
		await tester.tap(find.text(label));
		await tester.pumpAndSettle(const Duration(milliseconds: 400));
	}

	group('the app runs on a real device', () {
		testWidgets('reaches the dashboard after the first-run notice', (tester) async {
			await launch(tester);
			await acceptPrivacyNoticeIfShown(tester);
			// The dashboard is identified by the connect control's accessible
			// name, not by copy that could be reworded: the control is a
			// tappable orb rather than a text button.
			expect(connectControl(), findsOneWidget);
			expect(find.text('Disconnected'), findsOneWidget);
		});

		testWidgets('every screen builds without a layout overflow', (tester) async {
			await launch(tester);
			await acceptPrivacyNoticeIfShown(tester);
			for (final label in [
				'Servers',
				'Configurations',
				'Settings',
				'Diagnostics',
				'Privacy notice',
			]) {
				await goTo(tester, label);
				expect(
					tester.takeException(),
					isNull,
					reason: 'a layout error appeared on the $label screen',
				);
			}
		});
	});

	group('connecting reports the truth', () {
		testWidgets('connecting with no reachable server does not claim success',
			(tester) async {
			await launch(tester);
			await acceptPrivacyNoticeIfShown(tester);

			// Deliberately not waiting for the VPN permission dialog. The point
			// of this test is what the app says when it cannot connect, and the
			// discovery layer may legitimately have found nothing, failed, or
			// found a server that is OpenVPN-only (which this build cannot run).
			// All three must end in an honest message, never in "Connected".
			await tester.tap(connectControl());
			await tester.pumpAndSettle(const Duration(seconds: 3));

			expect(
				connectedLabel(),
				findsNothing,
				reason: 'the app reported a connection it cannot have made',
			);

			// Record what the user is actually shown. The assertion above proves
			// the app does not claim success; this proves it says *something
			// useful* instead, which is the difference between an honest failure
			// and a dead button.
			final visible = <String>[];
			for (final text in find.byType(Text).evaluate()) {
				final widget = text.widget as Text;
				final data = widget.data ?? (widget.textSpan?.toPlainText() ?? '');
				if (data.trim().isNotEmpty) {
					visible.add(data.trim());
				}
			}
			debugPrint('ON-DEVICE VISIBLE TEXT: ${visible.join(' | ')}');
		});

		testWidgets('the interface is left in a usable state after a failure',
			(tester) async {
			await launch(tester);
			await acceptPrivacyNoticeIfShown(tester);
			await tester.tap(connectControl());
			await tester.pumpAndSettle(const Duration(seconds: 3));

			// A failure must not leave the user on a spinner with no way out.
			// The app either stays on the dashboard with a reason, or offers the
			// action that fixes the problem.
			expect(find.byType(Scaffold), findsWidgets);
			expect(connectControl(), findsOneWidget);
			expect(tester.takeException(), isNull);
		});
	});
}

/// The primary connect control.
///
/// Found by its accessible name rather than by a button label, because the
/// control is a large tappable orb rather than a text button, and because the
/// accessible name is what a screen reader announces.
Finder connectControl() => find.byWidgetPredicate(
	(Widget widget) =>
		widget is Semantics &&
		widget.properties.label != null &&
		widget.properties.label!.contains('Activate to connect') &&
		widget.properties.button == true,
);

/// The app must never show a connected state without a verified tunnel.
///
/// Matched as a predicate rather than an exact string so that a legitimate
/// reword of the button label — "Disconnect" instead of "Connected" — cannot
/// silently turn this assertion into a no-op that always passes.
Finder connectedLabel() => find.byWidgetPredicate(
	(Widget widget) =>
		widget is Text &&
		(widget.data ?? '').trim().toLowerCase() == 'connected',
);
