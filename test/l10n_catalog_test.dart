import 'package:flutter_test/flutter_test.dart';

import 'package:phantrix/l10n/strings.dart';

void main() {
  test('the Arabic catalog covers every English key', () {
    final en = L10n.catalog['en']!.keys.toSet();
    final ar = L10n.catalog['ar']!.keys.toSet();
    expect(
      en.difference(ar),
      isEmpty,
      reason: 'a missing key falls back to English on an Arabic screen',
    );
  });

  test('the Arabic catalog invents no keys of its own', () {
    final en = L10n.catalog['en']!.keys.toSet();
    final ar = L10n.catalog['ar']!.keys.toSet();
    expect(
      ar.difference(en),
      isEmpty,
      reason: 'a key only Arabic knows would translate nothing',
    );
  });

  test('no Arabic string is empty', () {
    for (final entry in L10n.catalog['ar']!.entries) {
      expect(entry.value.trim(), isNotEmpty, reason: entry.key);
    }
  });
}
