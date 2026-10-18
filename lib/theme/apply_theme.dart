part of 'app_theme.dart';

ThemeData applyThemeData(ThemeData base, String animationLevel) {
  final scheme = base.colorScheme;
  final isDark = base.brightness == Brightness.dark;
  final ink = scheme.onSurface;
  final muted = scheme.onSurfaceVariant;
  final line = scheme.outline;
  final tint = isDark ? Colors.black : const Color(0xFF1E3A2B);

  final text = base.textTheme
      .apply(bodyColor: ink, displayColor: ink, fontFamily: 'Inter')
      .copyWith(
        displayLarge: _themeStyle(
          52,
          FontWeight.w700,
          ink,
          height: 1.06,
          spacing: -1.4,
        ),
        displayMedium: _themeStyle(
          40,
          FontWeight.w700,
          ink,
          height: 1.1,
          spacing: -1.0,
        ),
        displaySmall: _themeStyle(
          32,
          FontWeight.w600,
          ink,
          height: 1.16,
          spacing: -0.6,
        ),
        headlineMedium: _themeStyle(
          26,
          FontWeight.w600,
          ink,
          height: 1.22,
          spacing: -0.4,
        ),
        headlineSmall: _themeStyle(
          21,
          FontWeight.w600,
          ink,
          height: 1.28,
          spacing: -0.2,
        ),
        titleLarge: _themeStyle(
          17,
          FontWeight.w600,
          ink,
          height: 1.32,
          spacing: -0.1,
        ),
        titleMedium: _themeStyle(15, FontWeight.w600, ink, height: 1.36),
        titleSmall: _themeStyle(13.5, FontWeight.w600, muted, height: 1.4),
        bodyLarge: _themeStyle(15, FontWeight.w400, ink, height: 1.5),
        bodyMedium: _themeStyle(13.5, FontWeight.w400, muted, height: 1.55),
        bodySmall: _themeStyle(12.5, FontWeight.w400, muted, height: 1.5),
        labelLarge: _themeStyle(
          14,
          FontWeight.w600,
          ink,
          height: 1.2,
          spacing: 0.1,
        ),
        labelMedium: _themeStyle(
          12.5,
          FontWeight.w600,
          muted,
          height: 1.2,
          spacing: 0.2,
        ),
        labelSmall: _themeStyle(
          11.5,
          FontWeight.w700,
          muted,
          height: 1.2,
          spacing: 0.6,
        ),
      )
      .apply(fontFamily: 'Inter', fontFamilyFallback: VgType.sans);

  final themed = applyThemeCopyA(base, text, scheme, ink, muted, line);
  return applyThemeCopyB(themed, text, scheme, ink, muted, line, tint, animationLevel);
}

TextStyle _themeStyle(
  double size,
  FontWeight weight,
  Color color, {
  double? height,
  double? spacing,
}) {
  return TextStyle(
    fontSize: size,
    fontWeight: weight,
    color: color,
    height: height,
    letterSpacing: spacing,
  );
}
