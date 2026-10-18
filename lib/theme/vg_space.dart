part of 'tokens.dart';

class VgSpace {
  VgSpace._();

  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
  static const double xxxl = 48;

  /// The page gutter. Wider on a large window so a line of text never
  /// becomes uncomfortably long.
  static double gutter(double width) {
    if (width >= 1000) {
      return xxl;
    }
    if (width >= 700) {
      return xl;
    }
    return lg;
  }

  /// The widest a single column of reading content may become.
  ///
  /// Long measures are hard to read. Capping the column is what keeps a
  /// windowed app looking composed on a 4K display instead of stretched.
  /// This is the cap for one-column screens — settings, licences, privacy —
  /// where a single measure of text is the whole layout.
  static const double maxContentWidth = 680;

  /// The widest a multi-column layout may become.
  ///
  /// Two-column screens (the dashboard) are not a measure of text; they are
  /// a dashboard, so they are allowed to be wider before they start to
  /// stretch. They still stop, because an unbounded dashboard on a 4K
  /// display reads as a browser window that lost the plot.
  static const double maxDashboardWidth = 1160;

  /// Vertical rhythm between two sibling panels on a wide screen.
  static const double columnGap = 20;
}
