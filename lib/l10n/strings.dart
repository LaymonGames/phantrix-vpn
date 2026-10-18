library;

import 'package:flutter/widgets.dart';

part 'strings_values.dart';
part 'strings_values_en.dart';
part 'strings_values_ar.dart';
part 'strings_problems.dart';

/// English and Arabic strings used by the UI.
///
/// Every string the user can see lives here. Nothing is hardcoded in a widget,
/// because a right-to-left layout with Arabic names has to be testable, and
/// because the honest way to support a second language is to make the first
/// one structured.
class L10n {
  const L10n(this.languageCode);

  final String languageCode;

  bool get isRtl => languageCode == 'ar';

  static const L10n en = L10n('en');
  static const L10n ar = L10n('ar');

  static const List<Locale> supportedLocales = [Locale('en'), Locale('ar')];

  /// The complete catalogs, keyed by language code. Exposed for the test that
  /// keeps the two languages in step; the UI reads strings through [get].
  @visibleForTesting
  static const Map<String, Map<String, String>> catalog = _stringsValues;

  static L10n of(BuildContext context) {
    final locale = Localizations.localeOf(context);
    return locale.languageCode == 'ar' ? ar : en;
  }

  /// The string [key] stands for, with every `placeholder` in [params]
  /// replaced by its value.
  ///
  /// [params] is optional; keys without parameters pass no map at all. An
  /// entry the current language's sentence does not mention is simply
  /// unused — one language may spell a count where the other folds it into
  /// the sentence.
  String get(String key, [Map<String, String>? params]) {
    var value =
        _stringsValues[languageCode]?[key] ??
        _stringsValues['en']![key] ??
        key;
    if (params == null || params.isEmpty) {
      return value;
    }
    params.forEach((name, replacement) {
      value = value.replaceFirst('{$name}', replacement);
    });
    return value;
  }

  /// The app's own message for a platform error [code], or null when the
  /// code keeps the message the native side sent.
  ///
  /// The native layer reports failure reasons in English only, so codes
  /// with a fixed, human sentence — the ones a user acts on — have app-side
  /// translations. Codes that carry file paths or one-off engine reports
  /// are deliberately absent: paraphrasing a path would make it wrong.
  /// The connection layer falls back to the native message for those.
  String? problem(String code, [Map<String, String>? params]) {
    final value =
        _problemValues[languageCode]?[code] ??
        _problemValues['en']?[code];
    if (value == null) {
      return null;
    }
    if (params == null || params.isEmpty) {
      return value;
    }
    var formatted = value;
    params.forEach((name, replacement) {
      formatted = formatted.replaceFirst('{$name}', replacement);
    });
    return formatted;
  }
}
