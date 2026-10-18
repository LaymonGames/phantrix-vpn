part of 'tokens.dart';

class VgType {
  VgType._();

  static const List<String> sans = <String>[
    'Inter',
    'Segoe UI Variable Display',
    'Segoe UI',
    'Roboto',
    'Helvetica Neue',
    'system-ui',
  ];

  static const List<String> mono = <String>[
    'Cascadia Code',
    'JetBrains Mono',
    'SF Mono',
    'Menlo',
    'Consolas',
    'monospace',
  ];

  /// Tabular figures for anything that counts.
  ///
  /// A session timer that jitters in width as the digits change looks broken;
  /// tabular figures are what stop that.
  static const List<FontFeature> tabular = [FontFeature.tabularFigures()];
}
