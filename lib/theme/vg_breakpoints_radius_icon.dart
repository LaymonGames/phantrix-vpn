part of 'tokens.dart';

class VgBreakpoints {
  VgBreakpoints._();

  /// At or above this the app uses the desktop sidebar.
  static const double sidebar = 900;

  /// At or above this the dashboard may use two columns.
  static const double twoColumn = 1000;

  /// At or above this the servers screen may use a wider measure.
  static const double wideMeasure = 1100;
}

class VgRadius {
  VgRadius._();

  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 22;
  static const double pill = 999;
}

class VgIcon {
  VgIcon._();

  /// Inline with body text. The default.
  static const double sm = 16;

  /// In a list row or a button. The workhorse.
  static const double md = 20;

  /// A screen's single hero icon.
  static const double lg = 28;
}
