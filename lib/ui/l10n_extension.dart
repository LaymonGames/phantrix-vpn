part of 'shell.dart';

extension L10nX on BuildContext {
  L10n get l10n => L10n.of(this);

  String tr(String key, [Map<String, String>? params]) =>
      l10n.get(key, params);
}
