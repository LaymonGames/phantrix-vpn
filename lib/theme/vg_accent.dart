part of 'app_theme.dart';

/// One accent the user can pick.
class VgAccentPreset {
  const VgAccentPreset(this.id, this.color);

  /// A stable key for the localised name (`accent.<id>`).
  final String id;
  final Color color;
}

/// Turns one user-chosen colour into the forms each theme needs.
///
/// The user picks a hue; the app is responsible for keeping it readable. A
/// light accent is unreadable as text on white and a dark one disappears on
/// the near-black canvas, so each theme gets a tone of the same hue that
/// passes WCAG AA against its own surfaces instead of the raw value.
class VgAccent {
  VgAccent._();

  static const Color phantrixGreen = Color(0xFF4ADE80);

  /// The curated set shown as swatches. Phantrix green first: it is the
  /// brand, and the default.
  static const List<VgAccentPreset> presets = [
    VgAccentPreset('green', phantrixGreen),
    VgAccentPreset('jade', Color(0xFF34D399)),
    VgAccentPreset('teal', Color(0xFF2DD4BF)),
    VgAccentPreset('sky', Color(0xFF38BDF8)),
    VgAccentPreset('indigo', Color(0xFF818CF8)),
    VgAccentPreset('violet', Color(0xFFC084FC)),
    VgAccentPreset('rose', Color(0xFFFB7185)),
    VgAccentPreset('amber', Color(0xFFFBBF24)),
  ];

  /// A vivid colour of [hue] (0–360), for the custom hue slider.
  static Color fromHue(double hue) =>
      HSLColor.fromAHSL(1, hue % 360, 0.78, 0.62).toColor();

  /// WCAG contrast ratio between two opaque colours.
  static double contrast(Color a, Color b) {
    final la = a.computeLuminance();
    final lb = b.computeLuminance();
    final hi = la > lb ? la : lb;
    final lo = la > lb ? lb : la;
    return (hi + 0.05) / (lo + 0.05);
  }

  /// The accent as it appears on the dark theme: bright enough to read as
  /// text on the darkest card.
  static Color forDark(Color accent, Color surface) {
    var hsl = HSLColor.fromColor(accent);
    if (hsl.saturation > 0.92) {
      hsl = hsl.withSaturation(0.92);
    }
    var guard = 0;
    while (contrast(hsl.toColor(), surface) < 7 && guard++ < 40) {
      hsl = hsl.withLightness((hsl.lightness + 0.02).clamp(0.0, 0.92));
    }
    return hsl.toColor();
  }

  /// The accent as it appears on the light theme: dark enough to carry
  /// white text and to read as text on white.
  static Color forLight(Color accent, {Color against = Colors.white}) {
    var hsl = HSLColor.fromColor(accent);
    var guard = 0;
    while ((contrast(hsl.toColor(), against) < 4.6 ||
            contrast(hsl.toColor(), Colors.white) < 4.6) &&
        guard++ < 60) {
      hsl = hsl.withLightness((hsl.lightness - 0.015).clamp(0.08, 1.0));
    }
    return hsl.toColor();
  }

  /// Text that sits on a filled accent.
  static Color onAccent(Color fill) =>
      contrast(fill, Colors.white) >= contrast(fill, const Color(0xFF06110B))
      ? Colors.white
      : const Color(0xFF06110B);

  /// A surface nudged a few percent toward the accent, so a whole theme
  /// shares the user's hue instead of only its buttons.
  static Color tint(Color surface, Color accent, double amount) =>
      Color.lerp(surface, accent, amount)!;
}

/// Theme-dependent decoration that [ColorScheme] has no slot for.
///
/// Read with `VgDecor.of(context)`. Components use it for the things that
/// differ in kind, not only in colour, between the two themes: the light
/// theme separates cards with a soft shadow, the dark theme with a hairline
/// and a tonal step.
@immutable
class VgDecor extends ThemeExtension<VgDecor> {
  const VgDecor({
    required this.canvas,
    required this.canvasGlow,
    required this.cardBorder,
    required this.cardShadow,
    required this.liftedShadow,
    required this.accentSoft,
    required this.accentLine,
    required this.sidebar,
  });

  /// The page background.
  final Color canvas;

  /// A faint wash of the accent at the top of the page.
  final Color canvasGlow;

  /// The hairline around a card.
  final Color cardBorder;

  final List<BoxShadow> cardShadow;
  final List<BoxShadow> liftedShadow;

  /// The accent at low strength, for selected rows and icon wells.
  final Color accentSoft;

  /// The accent at medium strength, for outlines of selected things.
  final Color accentLine;

  /// The navigation sidebar's fill.
  final Color sidebar;

  static VgDecor of(BuildContext context) =>
      Theme.of(context).extension<VgDecor>() ?? _fallback;

  static const VgDecor _fallback = VgDecor(
    canvas: VgColors.surface,
    canvasGlow: Color(0x00000000),
    cardBorder: VgColors.line,
    cardShadow: [],
    liftedShadow: [],
    accentSoft: Color(0x224ADE80),
    accentLine: Color(0x664ADE80),
    sidebar: VgColors.surfaceRaised,
  );

  @override
  VgDecor copyWith({
    Color? canvas,
    Color? canvasGlow,
    Color? cardBorder,
    List<BoxShadow>? cardShadow,
    List<BoxShadow>? liftedShadow,
    Color? accentSoft,
    Color? accentLine,
    Color? sidebar,
  }) => VgDecor(
    canvas: canvas ?? this.canvas,
    canvasGlow: canvasGlow ?? this.canvasGlow,
    cardBorder: cardBorder ?? this.cardBorder,
    cardShadow: cardShadow ?? this.cardShadow,
    liftedShadow: liftedShadow ?? this.liftedShadow,
    accentSoft: accentSoft ?? this.accentSoft,
    accentLine: accentLine ?? this.accentLine,
    sidebar: sidebar ?? this.sidebar,
  );

  @override
  VgDecor lerp(covariant VgDecor? other, double t) {
    if (other == null) {
      return this;
    }
    return VgDecor(
      canvas: Color.lerp(canvas, other.canvas, t)!,
      canvasGlow: Color.lerp(canvasGlow, other.canvasGlow, t)!,
      cardBorder: Color.lerp(cardBorder, other.cardBorder, t)!,
      cardShadow: BoxShadow.lerpList(cardShadow, other.cardShadow, t) ?? [],
      liftedShadow:
          BoxShadow.lerpList(liftedShadow, other.liftedShadow, t) ?? [],
      accentSoft: Color.lerp(accentSoft, other.accentSoft, t)!,
      accentLine: Color.lerp(accentLine, other.accentLine, t)!,
      sidebar: Color.lerp(sidebar, other.sidebar, t)!,
    );
  }
}
