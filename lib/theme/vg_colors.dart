part of 'tokens.dart';

class VgColors {
  VgColors._();

  // ---- Dark surfaces, from furthest back to closest ----
  static const Color surface = Color(0xFF080B0A);
  static const Color surfaceRaised = Color(0xFF0F1412);
  static const Color surfaceHigh = Color(0xFF161D1A);
  static const Color surfaceHighest = Color(0xFF1E2723);
  static const Color surfaceOverlay = Color(0xFF28332E);

  static const Color line = Color(0xFF1B2420);
  static const Color lineStrong = Color(0xFF2A3731);

  // ---- Ink ----
  static const Color ink = Color(0xFFEFF5F1);
  static const Color inkMuted = Color(0xFF9AAAA2);
  static const Color inkFaint = Color(0xFF6A7A72);

  // ---- State ----
  //
  // Each has a filled form, a soft form for tinted backgrounds, and a
  // border form for outlines. Using one colour at three opacities instead of
  // three separate hexes keeps the relationships obvious.
  static const Color connected = Color(0xFF2FD79F);
  static const Color connectedDeep = Color(0xFF0B5C42);
  static const Color connecting = Color(0xFF5B8CFF);
  static const Color connectingDeep = Color(0xFF1F3D8F);
  static const Color warning = Color(0xFFF5C453);
  static const Color warningDeep = Color(0xFF6E5110);
  static const Color danger = Color(0xFFFF6B6B);
  static const Color dangerDeep = Color(0xFF7A2A2A);

  /// The accent used for selection and focus, distinct from the state
  /// colours so that "selected" never reads as "connected".
  static const Color accent = Color(0xFF4ADE80);
  static const Color accentDeep = Color(0xFF14532D);

  // ---- Light theme ----
  static const Color lightSurface = Color(0xFFF3F7F4);
  static const Color lightSurfaceRaised = Color(0xFFFFFFFF);
  static const Color lightSurfaceHigh = Color(0xFFFFFFFF);
  static const Color lightSurfaceHighest = Color(0xFFE8EFEA);
  static const Color lightLine = Color(0xFFDCE5DF);
  static const Color lightLineStrong = Color(0xFFBFCDC4);
  static const Color lightInk = Color(0xFF0C1712);
  static const Color lightInkMuted = Color(0xFF52645A);
  static const Color lightInkFaint = Color(0xFF7B8C82);

  /// The accent that passes AA against a light background.
  ///
  /// The dark-theme accent is far too light to carry text on white, so the
  /// light theme gets its own value rather than the same hex reused and
  /// then discovered to be unreadable.
  static const Color lightAccent = Color(0xFF11743A);
  static const Color lightConnected = Color(0xFF0B7A57);
}
