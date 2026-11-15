library;

import 'package:flutter/material.dart';

import 'tokens.dart';

part 'apply_theme.dart';
part 'apply_theme_copy_a.dart';
part 'apply_theme_copy_b.dart';
part 'transitions.dart';
part 'ambient_glow.dart';
part 'vg_scaffold.dart';
part 'vg_accent.dart';

/// Builds the light and dark themes.
///
/// Both share one type scale, one set of shapes and one motion set, so
/// switching themes is only ever a colour change and never a layout one. A
/// theme that rearranged things would make "switch to light" a different
/// application rather than a different appearance.
///
/// ## The one rule that matters here
///
/// `primary` is the **accent** — the user's chosen colour (Phantrix green by
/// default), meaning "interactive". It is not the connected green. State
/// colour lives in [VgColors] and is applied deliberately, so "you can press
/// this" and "your traffic is going through a server" never share a meaning,
/// whichever accent the user picks.
///
/// ## How the accent is used
///
/// The chosen colour is never used raw. Each theme derives a tone of the same
/// hue that passes contrast against its own surfaces ([VgAccent.forDark],
/// [VgAccent.forLight]), and the neutral surfaces are tinted a few percent
/// toward it, so a violet accent gives a violet-tinged night rather than
/// violet buttons pasted onto a green one.
class AppTheme {
  const AppTheme._();

  static ThemeData dark({
    required String animationLevel,
    Color accent = VgAccent.phantrixGreen,
  }) => _apply(_darkBase(accent), animationLevel);

  static ThemeData light({
    required String animationLevel,
    Color accent = VgAccent.phantrixGreen,
  }) => _apply(_lightBase(accent), animationLevel);

  static ThemeData _darkBase(Color chosen) {
    Color t(Color c, double amount) => VgAccent.tint(c, chosen, amount);
    final canvas = t(VgColors.surface, 0.025);
    final card = t(VgColors.surfaceRaised, 0.035);
    final accent = VgAccent.forDark(chosen, card);
    final scheme = ColorScheme.dark(
      primary: accent,
      onPrimary: VgAccent.onAccent(accent),
      primaryContainer: t(VgColors.surfaceHigh, 0.16),
      onPrimaryContainer: accent,
      secondary: Color.lerp(accent, Colors.white, 0.45)!,
      onSecondary: const Color(0xFF06170D),
      tertiary: VgColors.warning,
      onTertiary: const Color(0xFF231900),
      error: VgColors.danger,
      onError: const Color(0xFF2B0000),
      surface: canvas,
      onSurface: VgColors.ink,
      onSurfaceVariant: VgColors.inkMuted,
      outline: t(VgColors.line, 0.05),
      outlineVariant: t(VgColors.lineStrong, 0.06),
      surfaceContainerLowest: canvas,
      surfaceContainerLow: card,
      surfaceContainer: t(VgColors.surfaceHigh, 0.04),
      surfaceContainerHigh: t(VgColors.surfaceHighest, 0.05),
      surfaceContainerHighest: t(VgColors.surfaceOverlay, 0.06),
      inverseSurface: VgColors.ink,
      onInverseSurface: canvas,
      inversePrimary: VgAccent.forLight(chosen),
      shadow: Colors.black,
    );
    final decor = VgDecor(
      canvas: canvas,
      canvasGlow: accent.withValues(alpha: 0.07),
      cardBorder: Colors.white.withValues(alpha: 0.06),
      cardShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.35),
          blurRadius: 24,
          offset: const Offset(0, 10),
          spreadRadius: -10,
        ),
      ],
      liftedShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.40),
          blurRadius: 40,
          offset: const Offset(0, 16),
          spreadRadius: -18,
        ),
      ],
      accentSoft: accent.withValues(alpha: 0.12),
      accentLine: accent.withValues(alpha: 0.38),
      sidebar: t(const Color(0xFF0A0F0D), 0.03),
    );
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: canvas,
      canvasColor: canvas,
      splashFactory: InkSparkle.splashFactory,
      extensions: [decor],
    );
  }

  static ThemeData _lightBase(Color chosen) {
    Color t(Color c, double amount) => VgAccent.tint(c, chosen, amount);
    // Not pure white: a faintly tinted canvas lets white cards read as
    // objects and is easier on the eyes than a blank page.
    final canvas = t(VgColors.lightSurface, 0.035);
    final accent = VgAccent.forLight(chosen, against: canvas);
    final scheme = ColorScheme.light(
      primary: accent,
      onPrimary: VgAccent.onAccent(accent),
      primaryContainer: t(Colors.white, 0.14),
      onPrimaryContainer: accent,
      secondary: Color.lerp(accent, VgColors.lightInk, 0.25)!,
      onSecondary: Colors.white,
      tertiary: const Color(0xFF8A6100),
      onTertiary: Colors.white,
      error: const Color(0xFFC62828),
      onError: Colors.white,
      surface: canvas,
      onSurface: VgColors.lightInk,
      onSurfaceVariant: VgColors.lightInkMuted,
      outline: t(VgColors.lightLine, 0.04),
      outlineVariant: t(VgColors.lightLineStrong, 0.05),
      surfaceContainerLowest: Colors.white,
      surfaceContainerLow: Colors.white,
      surfaceContainer: t(const Color(0xFFF6F9F7), 0.03),
      surfaceContainerHigh: t(VgColors.lightSurfaceHighest, 0.04),
      surfaceContainerHighest: t(const Color(0xFFDDE7E1), 0.05),
      inverseSurface: VgColors.lightInk,
      onInverseSurface: Colors.white,
      inversePrimary: VgAccent.forDark(chosen, const Color(0xFF0E1412)),
      shadow: const Color(0xFF0E2A1C),
    );
    final decor = VgDecor(
      canvas: canvas,
      canvasGlow: accent.withValues(alpha: 0.06),
      cardBorder: t(const Color(0xFFE1E9E4), 0.03),
      cardShadow: [
        BoxShadow(
          color: const Color(0xFF0E2A1C).withValues(alpha: 0.05),
          blurRadius: 2,
          offset: const Offset(0, 1),
        ),
        BoxShadow(
          color: const Color(0xFF0E2A1C).withValues(alpha: 0.06),
          blurRadius: 24,
          offset: const Offset(0, 10),
          spreadRadius: -8,
        ),
      ],
      liftedShadow: [
        BoxShadow(
          color: const Color(0xFF0E2A1C).withValues(alpha: 0.12),
          blurRadius: 44,
          offset: const Offset(0, 20),
          spreadRadius: -14,
        ),
      ],
      accentSoft: accent.withValues(alpha: 0.09),
      accentLine: accent.withValues(alpha: 0.35),
      sidebar: Colors.white,
    );
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: scheme,
      scaffoldBackgroundColor: canvas,
      canvasColor: canvas,
      splashFactory: InkSparkle.splashFactory,
      extensions: [decor],
    );
  }

  static ThemeData _apply(ThemeData base, String animationLevel) =>
      applyThemeData(base, animationLevel);
}
