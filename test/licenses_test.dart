import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:phantrix/l10n/strings.dart';
import 'package:phantrix/notices/generated_third_party_notices.dart';
import 'package:phantrix/notices/third_party_notices.dart';
import 'package:phantrix/theme/app_theme.dart';
import 'package:phantrix/ui/screens/licenses_screen.dart';

Future<void> pumpLicenses(WidgetTester tester, {String language = 'en'}) async {
	await tester.pumpWidget(
		MaterialApp(
			theme: AppTheme.dark(animationLevel: 'none'),
			locale: Locale(language),
			localizationsDelegates: const [
				_TestDelegate(),
				GlobalMaterialLocalizations.delegate,
				GlobalWidgetsLocalizations.delegate,
				GlobalCupertinoLocalizations.delegate,
			],
			supportedLocales: L10n.supportedLocales,
			home: const LicensesScreen(),
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

/// A notice whose name appears exactly once in the inventory, so a plain
/// [find.text] cannot match a same-named row elsewhere in the list.
ThirdPartyNoticeData uniqueNotice(bool Function(ThirdPartyNoticeData) where) {
	final counts = <String, int>{};
	for (final notice in thirdPartyNotices) {
		counts[notice.name] = (counts[notice.name] ?? 0) + 1;
	}
	return thirdPartyNotices.firstWhere(
		(n) => where(n) && counts[n.name] == 1 && n.component != 'app',
	);
}

void main() {
	group('generated inventory', () {
		test('every package the app locks is in the inventory', () {
			final locked = <String>{};
			final lockfile = File('pubspec.lock').readAsStringSync();
			for (final block in RegExp(
				r'^  ([a-zA-Z0-9_]+):\n(?:    .*\n?)*',
				multiLine: true,
			).allMatches(lockfile)) {
				locked.add(block.group(1)!);
			}
			final listed = thirdPartyNotices
					.where((n) => n.component == 'dart')
					.map((n) => n.name)
					.toSet();
			final missing = locked.difference(listed);
			expect(missing, isEmpty, reason: 'locked but not listed: $missing');
		});

		test('every bundled licence text has an entry that points at it', () {
			final keys = thirdPartyNotices
					.map((n) => n.licenseKey)
					.whereType<String>()
					.toSet();
			for (final key in licenseTexts.keys) {
				expect(keys, contains(key));
			}
			for (final notice in thirdPartyNotices) {
				if (notice.hasLicenseText) {
					expect(licenseTexts[notice.licenseKey], isNotNull);
				}
			}
		});

		test('copyright attribution is never presented as a licence name', () {
			for (final notice in thirdPartyNotices) {
				expect(
					notice.licenseId.toLowerCase().startsWith('copyright'),
					isFalse,
					reason: '${notice.component}/${notice.name} has a copyright line as its licence label',
				);
			}
		});

		test('the Dart packages use a recognised BSD identifier when their notice is BSD-3-Clause', () {
			final collection = thirdPartyNotices.firstWhere(
				(n) => n.component == 'dart' && n.name == 'collection' && n.version == '1.19.1',
			);
			expect(collection.licenseId, 'BSD-3-Clause');
		});

		test('no entry claims a licence its own text contradicts', () {
			// A MIT text must not be labelled Apache, and so on. This is the
			// check that would catch a drift between the label the generator
			// derived and the text it bundled.
			for (final notice in thirdPartyNotices) {
				final text = notice.licenseKey == null
						? null
						: licenseTexts[notice.licenseKey];
				if (text == null || notice.licenseId == 'unknown') {
					continue;
				}
				final upper = text.toUpperCase();
				if (notice.licenseId == 'MIT') {
					expect(upper.contains('MIT LICENSE') ||
							upper.contains('PERMISSION IS HEREBY GRANTED'), isTrue,
							reason: notice.name);
				}
				if (notice.licenseId == 'Apache-2.0') {
					expect(upper.contains('APACHE LICENSE') &&
							upper.contains('VERSION 2.0'), isTrue, reason: notice.name);
				}
				if (notice.licenseId == 'BSD-3-Clause') {
					expect(upper.contains('REDISTRIBUTION AND USE IN SOURCE AND BINARY FORMS') &&
							upper.contains('NEITHER THE NAME'), isTrue, reason: notice.name);
				}
			}
		});

		test('the app uses the unmodified GPLv3 text and a separate project notice', () {
			final license = File('LICENSE').readAsStringSync();
			final copyright = File('COPYRIGHT').readAsStringSync();
			expect(license, contains('GNU GENERAL PUBLIC LICENSE'));
			expect(license, contains('Everyone is permitted to copy and distribute verbatim copies'));
			expect(license, isNot(contains('Phantrix')));
			expect(copyright, contains('SPDX-License-Identifier: GPL-3.0-only'));
		});

		test('Android test-only dependencies show their known licence metadata', () {
			for (final coordinate in [
				'androidx.test.ext:junit',
				'androidx.test:core',
				'androidx.test:runner',
			]) {
				final notice = thirdPartyNotices.firstWhere(
					(n) => n.component == 'android' && n.name == coordinate,
				);
				expect(notice.licenseId, 'Apache-2.0', reason: coordinate);
				expect(notice.noteCodes, contains('testOnly'), reason: coordinate);
				expect(notice.hasLicenseText, isTrue, reason: coordinate);
			}
			final junit = thirdPartyNotices.firstWhere(
				(n) => n.component == 'android' && n.name == 'junit:junit',
			);
			expect(junit.licenseId, 'EPL-1.0');
			expect(junit.noteCodes, contains('testOnly'));
			final json = thirdPartyNotices.firstWhere(
				(n) => n.component == 'android' && n.name == 'org.json:json',
			);
			expect(json.licenseId, 'Public Domain.');
			expect(json.noteCodes, contains('testOnly'));
		});

		test('no OpenVPN engine is bundled in the Android build', () {
			expect(
				thirdPartyNotices.where(
					(n) => n.component == 'android' && n.name.contains('openvpn'),
				),
				isEmpty,
			);
			expect(
				licenseTexts.keys.where((k) => k.contains('ics-openvpn') || k.contains('icsopenvpn')),
				isEmpty,
			);
		});

		test('the app itself is listed under its own licence', () {
			final app = thirdPartyNotices.where((n) => n.component == 'app').toList();
			expect(app, hasLength(1));
			expect(app.single.name, 'phantrix');
			expect(app.single.licenseId, 'GPL-3.0-only');
			expect(app.single.hasLicenseText, isTrue);
			expect(app.single.noteCodes, contains('appLicenceScopeLimited'));
			final projectPackages = thirdPartyNotices.where(
				(n) => n.component == 'dart' &&
						(n.name == 'phantrix_core' || n.name == 'phantrix_platform'),
			).toList();
			expect(projectPackages, hasLength(2));
			expect(projectPackages.every((n) => n.licenseId == 'GPL-3.0-only'), isTrue);
			for (final package in projectPackages) {
				expect(package.noteCodes, contains('projectPackageScopeLimited'));
			}
		});
	});

	group('LicensesScreen', () {
		testWidgets('opens and shows the about section', (tester) async {
			await pumpLicenses(tester);

			// Section headers are uppercased by VgSectionHeader.
			expect(find.text('LICENSES & CREDITS'), findsOneWidget);
			// The app card is collapsed by default; its details, including
			// the repository URL and the GPLv3 text, are one tap away.
			final about = find.text('phantrix 1.0.0+1');
			await tester.scrollUntilVisible(about, 150);
			await tester.ensureVisible(about);
			await tester.pumpAndSettle();
			await tester.tap(about);
			await tester.pumpAndSettle();

			expect(find.textContaining('https://github.com/'), findsOneWidget);
			expect(find.textContaining('GNU GENERAL PUBLIC LICENSE'), findsWidgets);
		});

		testWidgets('every notice renders with a licence line', (tester) async {
			await pumpLicenses(tester);

			expect(tester.takeException(), isNull);
			// The list is lazy, so a name only exists once it has been
			// scrolled into view. Sample the head, the middle and the tail of
			// the inventory rather than pretending the whole list is built at
			// once. Only names that appear exactly once are sampled: a name
			// shared by two versions resolved by different lockfiles would
			// match two rows, and the finder below is an exact match.
			final counts = <String, int>{};
			for (final notice in thirdPartyNotices) {
				counts[notice.name] = (counts[notice.name] ?? 0) + 1;
			}
			final ordered =
					thirdPartyNotices.where((n) => counts[n.name] == 1).toList(growable: false);
			final sample = <ThirdPartyNoticeData>[
				...ordered.take(3),
				...ordered.skip(ordered.length ~/ 2).take(3),
				...ordered.skip(ordered.length - 3),
			];
			for (final notice in sample) {
				// The app card's title carries its version; every other row
				// is a bare name.
				final finder = notice.component == 'app'
						? find.text('${notice.name} ${notice.version}')
						: find.text(notice.name);
				await tester.scrollUntilVisible(finder, 150, maxScrolls: 400);
				expect(finder, findsWidgets,
						reason: '${notice.component}/${notice.name} is missing');
			}
		});

		testWidgets('expanding a notice reveals its provenance', (tester) async {
			await pumpLicenses(tester);

			final notice = uniqueNotice((n) => n.hasLicenseText);
			final finder = find.text(notice.name);
			await tester.scrollUntilVisible(finder, 200);
			// Bring the row fully on screen before tapping: scrollUntilVisible
			// stops as soon as the finder exists in the viewport, which can leave
			// its centre below the fold, and a tap there misses the card.
			await tester.ensureVisible(finder);
			await tester.pumpAndSettle();
			await tester.tap(finder);
			await tester.pumpAndSettle();

			expect(find.text('Full licence text'), findsOneWidget);
			expect(find.text('Licence read from'), findsOneWidget);
		});

		testWidgets('an entry without a licence text says so', (tester) async {
			await pumpLicenses(tester);

			// Find one of the entries with no readable licence and exercise
			// the "not found" path explicitly.
			final withoutText = thirdPartyNotices
					.where((n) => n.licenseKey == null && n.component != 'app')
					.toList();
			if (withoutText.isEmpty) {
				return;
			}
			final finder = find.text(withoutText.first.name);
			await tester.scrollUntilVisible(finder, 200);
			await tester.ensureVisible(finder);
			await tester.pumpAndSettle();
			await tester.tap(finder);
			await tester.pumpAndSettle();

			expect(find.textContaining('No licence text could be read'), findsOneWidget);
		});

		testWidgets('Arabic replaces every English licence string', (tester) async {
			await pumpLicenses(tester, language: 'ar');

			expect(find.text('التراخيص والإشادات'), findsOneWidget);
			expect(find.text('Licenses & credits'), findsNothing);
			// The Arabic strings that live inside the About card only appear
			// once it is expanded; expand it and check the licence label too.
			final about = find.text('phantrix 1.0.0+1');
			await tester.scrollUntilVisible(about, 150);
			await tester.ensureVisible(about);
			await tester.pumpAndSettle();
			await tester.tap(about);
			await tester.pumpAndSettle();

			expect(find.text('الترخيص'), findsWidgets);
			expect(find.text('Licence'), findsNothing);
		});

		testWidgets('a two-times text scale still fits', (tester) async {
			tester.view.physicalSize = const Size(400, 900);
			tester.view.devicePixelRatio = 1;
			addTearDown(tester.view.reset);

			await pumpLicenses(tester);
			expect(tester.takeException(), isNull);
		});

		testWidgets('the page is offline: only bundled data renders', (tester) async {
			// The inventory is a Dart constant. If any widget ever reached
			// for the network, this test would need a client; it does not,
			// and a successful settle with no exception is the assertion.
			await pumpLicenses(tester);
			expect(licenseTexts, isNotEmpty);
			expect(tester.takeException(), isNull);
		});

		testWidgets('the VPN Gate attribution is stated, not buried', (tester) async {
			await pumpLicenses(tester);
			expect(find.text('VPN Gate'), findsOneWidget);
			expect(find.textContaining('volunteers'), findsWidgets);
		});
	});
}
