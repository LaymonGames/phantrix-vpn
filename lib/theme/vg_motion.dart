part of 'tokens.dart';

class VgMotion {
  VgMotion._();

  static const Duration fast = Duration(milliseconds: 140);
  static const Duration normal = Duration(milliseconds: 260);
  static const Duration slow = Duration(milliseconds: 420);

  /// One full turn of the orb's progress ring.
  static const Duration orbit = Duration(milliseconds: 2400);

  /// Curves. `emphasised` for anything the user initiated, `standard` for
  /// state settling on its own.
  static const Curve emphasised = Cubic(0.2, 0, 0, 1);
  static const Curve standard = Curves.easeOutCubic;
  static const Curve exit = Curves.easeInCubic;
}
