import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:phantrix/l10n/strings.dart';
import 'package:phantrix/notices/generated_third_party_notices.dart';
import 'package:phantrix/notices/third_party_notices.dart';
import 'package:phantrix/theme/app_theme.dart';
import 'package:phantrix/ui/screens/licenses_screen.dart';

/// The repository URL the project publishes under.
///
/// Pinned as a literal rather than imported from the generator, because the
/// point of the assertion below is that the *generated file* carries this
/// value, not that two references to the same constant agree.
const String canonicalRepositoryUrl =
    'https://github.com/LaymonGames/phantrix-vpn';

/// Reads a file with its line endings normalised.
///
/// A Windows checkout rewrites text files to CRLF, and a regex written
/// against `\n` then matches nothing — which is how the notice generator
/// silently produced a near-empty inventory on Windows.
String readNormalised(String path) =>
    File(path).readAsStringSync().replaceAll('\r\n', '\n');

Future<void> pumpLicenses(
  WidgetTester tester, {
  String language = 'en',
  List<ThirdPartyNoticeData>? notices,
}) async {
  // A tall window so a screen of cards is laid out without scrolling in the
  // tests that are about content rather than about scrolling.
  tester.view.physicalSize = const Size(1000, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.dark(animationLevel: 'none'),
      locale: Locale(language),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: L10n.supportedLocales,
      // The screen is a shell destination, so it is always built inside the
      // shell's Material ancestor. A bare `home:` would be a different tree
      // from the one the app builds.
      home: Scaffold(
        body: LicensesScreen(
          notices: notices ?? thirdPartyNotices,
          reducedMotion: true,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
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

/// Brings [finder] into view and pumps, returning false when it never appears.
///
/// The scrollable is named explicitly because the page contains a second,
/// inner scroll region — the bounded box a long licence text is rendered in —
/// and searching for `Scrollable` by type then finds two.
Future<bool> reveal(WidgetTester tester, Finder finder) async {
  try {
    await tester.scrollUntilVisible(
      finder,
      200,
      maxScrolls: 200,
      scrollable: find.byType(Scrollable).first,
    );
  } on StateError {
    return false;
  }
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  return true;
}

/// A finder for a row's own [Text].
///
/// `find.text` also matches an `EditableText`, so a search that types a
/// component's name into the search field would otherwise make that name look
/// like two matches.
Finder rowText(String value) =>
    find.byWidgetPredicate((widget) => widget is Text && widget.data == value);

void main() {
  group('generated inventory', () {
    test('every package the app locks is in the inventory', () {
      final locked = <String>{};
      for (final block in RegExp(
        r'^  ([a-zA-Z0-9_]+):\n(?:    .*\n?)*',
        multiLine: true,
      ).allMatches(readNormalised('pubspec.lock'))) {
        locked.add(block.group(1)!);
      }
      expect(
        locked,
        isNotEmpty,
        reason: 'the lockfile reader matched nothing, so this proves nothing',
      );
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
        expect(keys, contains(key), reason: '$key has no entry');
      }
      for (final notice in thirdPartyNotices) {
        if (notice.hasLicenseText) {
          expect(
            licenseTexts[notice.licenseKey],
            isNotNull,
            reason: '${notice.name} points at a missing text',
          );
        }
      }
    });

    test('copyright attribution is never presented as a licence name', () {
      for (final notice in thirdPartyNotices) {
        expect(
          notice.licenseId.toLowerCase().startsWith('copyright'),
          isFalse,
          reason:
              '${notice.component}/${notice.name} has a copyright line as '
              'its licence label',
        );
      }
    });

    test('no entry claims a licence its own text contradicts', () {
      // A MIT text must not be labelled Apache, and so on. This is the check
      // that would catch a drift between the label the generator derived and
      // the text it bundled.
      for (final notice in thirdPartyNotices) {
        final text = notice.licenseKey == null
            ? null
            : licenseTexts[notice.licenseKey];
        if (text == null || notice.licenseId == 'unknown') {
          continue;
        }
        final upper = text.toUpperCase();
        if (notice.licenseId == 'MIT') {
          expect(
            upper.contains('MIT LICENSE') ||
                upper.contains('PERMISSION IS HEREBY GRANTED'),
            isTrue,
            reason: notice.name,
          );
        }
        if (notice.licenseId == 'Apache-2.0') {
          expect(
            upper.contains('APACHE LICENSE') && upper.contains('VERSION 2.0'),
            isTrue,
            reason: notice.name,
          );
        }
        if (notice.licenseId == 'BSD-3-Clause') {
          expect(
            upper.contains(
                  'REDISTRIBUTION AND USE IN SOURCE AND BINARY FORMS',
                ) &&
                upper.contains('NEITHER THE NAME'),
            isTrue,
            reason: notice.name,
          );
        }
      }
    });

    test('the app uses the unmodified GPLv3 text and a separate notice', () {
      final license = readNormalised('LICENSE');
      final copyright = readNormalised('COPYRIGHT');
      expect(license, contains('GNU GENERAL PUBLIC LICENSE'));
      expect(
        license,
        contains(
          'Everyone is permitted to copy and distribute verbatim copies',
        ),
      );
      expect(
        license,
        isNot(contains('Phantrix')),
        reason: 'the GPL text must be the unmodified upstream text',
      );
      expect(copyright, contains('SPDX-License-Identifier: GPL-3.0-only'));
    });

    test('the Android build declares no third-party dependencies', () {
      // The Android app and the plugin compile against the Flutter embedding
      // and the Android framework and nothing else, so there is nothing to
      // attribute on that side — which is why the inventory has no `android`
      // component. Asserted rather than assumed, because a dependency added
      // to that Gradle file without a notice would make the inventory
      // silently incomplete.
      for (final file in [
        'android/app/build.gradle.kts',
        'packages/phantrix_platform/android/build.gradle.kts',
      ]) {
        expect(
          readNormalised(file).contains('implementation('),
          isFalse,
          reason: '$file declares a dependency; the inventory must list it',
        );
      }
      expect(thirdPartyNotices.where((n) => n.component == 'android'), isEmpty);
    });

    test('no OpenVPN engine is bundled in the Android build', () {
      expect(
        thirdPartyNotices.where(
          (n) => n.component == 'android' && n.name.contains('openvpn'),
        ),
        isEmpty,
      );
      expect(
        licenseTexts.keys.where(
          (k) => k.contains('ics-openvpn') || k.contains('icsopenvpn'),
        ),
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
        (n) =>
            n.component == 'dart' &&
            (n.name == 'phantrix_core' || n.name == 'phantrix_platform'),
      );
      expect(projectPackages, hasLength(2));
      expect(
        projectPackages.every((n) => n.licenseId == 'GPL-3.0-only'),
        isTrue,
      );
      for (final package in projectPackages) {
        expect(package.noteCodes, contains('projectPackageScopeLimited'));
      }
    });

    test('the inventory reports the version the package declares', () {
      // The About panel prints this number. A wrong version there is a wrong
      // version in every bug report a user files, so it is asserted against
      // `pubspec.yaml` rather than trusted.
      final declared = RegExp(
        r'^version:\s*(\S+)',
        multiLine: true,
      ).firstMatch(readNormalised('pubspec.yaml'))?.group(1);
      expect(declared, isNotNull, reason: 'pubspec.yaml has no version:');
      final app = ThirdPartyNotices.app(thirdPartyNotices);
      expect(app, isNotNull);
      expect(app!.version, declared);
    });

    test(
      'the inventory reports the canonical repository, not a stale remote',
      () {
        final declared = RegExp(
          r'^repository:\s*"?([^"\s]+)"?',
          multiLine: true,
        ).firstMatch(readNormalised('pubspec.yaml'))?.group(1);
        expect(declared, canonicalRepositoryUrl);
        final app = ThirdPartyNotices.app(thirdPartyNotices);
        expect(app?.sourceUrl, canonicalRepositoryUrl);
      },
    );

    test(
      'the generator never takes the repository URL from local Git state',
      () {
        // Reading `.git/config` meant the attribution a build carried depended
        // on whichever remote the developer's clone had: a stale clone stamped
        // a repository that no longer exists into the shipped notices. The URL
        // now comes from `pubspec.yaml`, and this is the guard that keeps it
        // that way.
        final source = readNormalised(
          'tools/generate_third_party_notices.dart',
        );
        expect(source.contains('.git/config'), isFalse);
        expect(source.contains('canonicalRepositoryUrl'), isTrue);
      },
    );

    test('every caveat code has a sentence in both languages', () {
      final codes = <String>{
        for (final notice in thirdPartyNotices) ...notice.noteCodes,
      };
      expect(codes, isNotEmpty);
      for (final code in codes) {
        final key = 'licensesNote_$code';
        for (final language in L10n.catalog.values) {
          expect(
            language[key],
            isNotNull,
            reason: '$key is missing from one language',
          );
          expect(
            language[key],
            isNot(key),
            reason: '$key has no sentence, so the raw key would be shown',
          );
        }
      }
    });

    test('search matches names, versions, licences and components', () {
      expect(
        ThirdPartyNotices.search(thirdPartyNotices, ''),
        hasLength(thirdPartyNotices.length),
      );
      expect(
        ThirdPartyNotices.search(thirdPartyNotices, '  ANALYZER '),
        isNotEmpty,
      );
      for (final notice in ThirdPartyNotices.search(thirdPartyNotices, 'gpl')) {
        expect(
          '${notice.name} ${notice.version} ${notice.licenseId} '
                  '${notice.component}'
              .toLowerCase()
              .contains('gpl'),
          isTrue,
        );
      }
      expect(
        ThirdPartyNotices.search(thirdPartyNotices, 'no-such-component'),
        isEmpty,
      );
    });
  });

  group('LicensesScreen', () {
    testWidgets('shows the application licence before anything else', (
      tester,
    ) async {
      await pumpLicenses(tester);
      expect(tester.takeException(), isNull);

      // Section headers are uppercased by VgSectionHeader.
      expect(
        find.text(L10n.en.get('licensesTitle').toUpperCase()),
        findsOneWidget,
      );
      expect(find.text(L10n.en.get('licensesIntro')), findsOneWidget);

      // The application's own licence is not behind a tap: the GPL text and
      // the copyright line are on the page as it opens.
      final app = ThirdPartyNotices.app(thirdPartyNotices)!;
      expect(find.text('${app.name} ${app.version}'), findsOneWidget);
      expect(find.textContaining('GNU GENERAL PUBLIC LICENSE'), findsWidgets);
      expect(find.text(app.copyright!), findsWidgets);
      expect(find.text(canonicalRepositoryUrl), findsOneWidget);
    });

    testWidgets('the GPL page states the no-warranty notice', (tester) async {
      await pumpLicenses(tester);
      // GPL-3.0's "Appropriate Legal Notices" for an interactive program are
      // the copyright notice, the absence of warranty and the way to view
      // the licence. The first two are asserted here, the third above.
      final intro = L10n.en.get('licensesIntro');
      expect(intro.toLowerCase(), contains('no warranty'));
      expect(intro.toLowerCase(), contains('gnu general public license'));
    });

    testWidgets('searching narrows the inventory to the match', (tester) async {
      await pumpLicenses(tester);

      // The last entry whose name is unique, so the assertion below is about
      // filtering rather than about what the first viewport happens to hold.
      final counts = <String, int>{};
      for (final notice in thirdPartyNotices) {
        counts[notice.name] = (counts[notice.name] ?? 0) + 1;
      }
      final target = thirdPartyNotices
          .where((n) => n.component != 'app' && counts[n.name] == 1)
          .last;
      expect(
        find.text(target.name),
        findsNothing,
        reason:
            'the target must start off-screen for this test to mean '
            'anything',
      );

      await tester.enterText(find.byType(TextField), target.name);
      await tester.pumpAndSettle();

      expect(rowText(target.name), findsOneWidget);
      // A package that was on screen before the search is not after it.
      expect(find.text('_fe_analyzer_shared'), findsNothing);
      // The standing prose is about the build, not about one package, so a
      // search that names a package leaves it out of the way.
      expect(find.text(L10n.en.get('licensesVpnGateTitle')), findsNothing);
    });

    testWidgets('a search that matches nothing says so', (tester) async {
      await pumpLicenses(tester);

      await tester.enterText(find.byType(TextField), 'zzz-no-such-thing');
      await tester.pumpAndSettle();

      expect(find.text(L10n.en.get('licensesEmptyTitle')), findsOneWidget);
      expect(
        find.textContaining('zzz-no-such-thing'),
        findsWidgets,
        reason: 'the empty state echoes what was searched for',
      );
    });

    testWidgets('expanding a notice reveals its provenance and full text', (
      tester,
    ) async {
      await pumpLicenses(tester);

      final notice = uniqueNotice((n) => n.hasLicenseText);
      expect(await reveal(tester, find.text(notice.name)), isTrue);
      await tester.tap(find.text(notice.name));
      await tester.pumpAndSettle();

      expect(find.text(L10n.en.get('licensesFullText')), findsOneWidget);
      expect(find.text(L10n.en.get('licensesProvenance')), findsOneWidget);
    });

    testWidgets('an entry without a licence text says so', (tester) async {
      // The generated inventory currently has a licence text for every entry,
      // so this path is driven from a supplied inventory rather than asserted
      // away. A row that looks licensed when nothing was read is the one
      // failure this page must not have.
      await pumpLicenses(
        tester,
        notices: const [
          ThirdPartyNoticeData(
            component: 'dart',
            name: 'a-package-with-no-readable-licence',
            version: '9.9.9',
            sourceUrl: 'https://example.invalid/a',
            licenseId: 'unknown',
            licenseSource: 'nothing readable in the pub cache',
          ),
        ],
      );

      expect(
        await reveal(tester, find.text('a-package-with-no-readable-licence')),
        isTrue,
      );
      await tester.tap(find.text('a-package-with-no-readable-licence'));
      await tester.pumpAndSettle();

      expect(find.text(L10n.en.get('licensesMissingText')), findsOneWidget);
      expect(find.textContaining('unknown'), findsWidgets);
      expect(find.text(L10n.en.get('licensesProvenance')), findsOneWidget);
    });

    testWidgets('a licence text is bounded rather than unbounded', (
      tester,
    ) async {
      // The GPL text is 35 KB. It is rendered in a bounded, scrollable box so
      // one entry cannot make the page unreasonable to scroll.
      await pumpLicenses(tester);
      final app = ThirdPartyNotices.app(thirdPartyNotices)!;
      final key = app.licenseKey!;
      final text = licenseTexts[key]!;
      expect(text.length, greaterThan(10000));

      final block = find
          .descendant(
            of: find.byType(SingleChildScrollView),
            matching: find.byType(SelectableText),
          )
          .first;
      final size = tester.getSize(find.byType(SingleChildScrollView).first);
      expect(block, findsOneWidget);
      expect(size.height, lessThanOrEqualTo(260));
    });

    testWidgets('Arabic replaces every English page string', (tester) async {
      await pumpLicenses(tester, language: 'ar');

      expect(
        find.text(L10n.ar.get('licensesTitle').toUpperCase()),
        findsOneWidget,
      );
      expect(find.text(L10n.ar.get('licensesIntro')), findsOneWidget);
      expect(find.text(L10n.ar.get('licensesSearchHint')), findsOneWidget);
      expect(
        find.text(L10n.en.get('licensesTitle').toUpperCase()),
        findsNothing,
      );
      expect(find.text(L10n.en.get('licensesSearchHint')), findsNothing);
      expect(find.text(L10n.en.get('licensesAppHeading')), findsNothing);
    });

    testWidgets('a two-times text scale still fits', (tester) async {
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(animationLevel: 'none'),
          locale: const Locale('en'),
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: L10n.supportedLocales,
          home: const MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(2)),
            child: Scaffold(body: LicensesScreen(reducedMotion: true)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('the VPN Gate attribution is stated, not buried', (
      tester,
    ) async {
      await pumpLicenses(tester);
      expect(find.text(L10n.en.get('licensesVpnGateTitle')), findsOneWidget);
    });

    testWidgets('the page is offline: only bundled data renders', (
      tester,
    ) async {
      // The inventory is a Dart constant. If any widget ever reached for the
      // network, this test would need a client; it does not, and a
      // successful settle with no exception is the assertion.
      await pumpLicenses(tester);
      expect(licenseTexts, isNotEmpty);
      expect(tester.takeException(), isNull);
    });
  });
}
