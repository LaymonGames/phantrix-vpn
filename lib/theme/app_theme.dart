library;

import 'package:flutter/material.dart';

import 'tokens.dart';

part 'apply_theme.dart';
part 'apply_theme_copy_a.dart';
part 'apply_theme_copy_b.dart';
part 'transitions.dart';
part 'ambient_glow.dart';
part 'vg_scaffold.dart';

/// Builds the light and dark themes.
///
/// Both share one type scale, one set of shapes and one motion set, so
/// switching themes is only ever a colour change and never a layout one. A
/// theme that rearranged things would make "switch to light" a different
/// application rather than a different appearance.
///
/// ## The one rule that matters here
///
/// `primary` is the **accent** — brand green, meaning "interactive". It is not the
/// connected green. In an earlier version of this theme `primary` was the
/// connected colour, which meant every filled button was green and every
/// selected row looked like a live tunnel. State colour lives in [VgColors]
/// and is applied deliberately, so "you can press this" and "your traffic is
/// going through a server" never share a hue.
class AppTheme {
  const AppTheme._();

  static ThemeData dark({required String animationLevel}) =>
      _apply(_darkBase(), animationLevel);

  static ThemeData light({required String animationLevel}) =>
      _apply(_lightBase(), animationLevel);

  static ThemeData _darkBase() {
    const scheme = ColorScheme.dark(
      primary: VgColors.accent,
      onPrimary: Color(0xFF04140B),
      secondary: Color(0xFFA7E8C0),
      onSecondary: Color(0xFF06170D),
      tertiary: VgColors.warning,
      onTertiary: Color(0xFF231900),
      error: VgColors.danger,
      onError: Color(0xFF2B0000),
      surface: VgColors.surface,
      onSurface: VgColors.ink,
      onSurfaceVariant: VgColors.inkMuted,
      outline: VgColors.line,
      outlineVariant: VgColors.lineStrong,
      surfaceContainerLowest: VgColors.surface,
      surfaceContainerLow: VgColors.surfaceRaised,
      surfaceContainer: VgColors.surfaceHigh,
      surfaceContainerHigh: VgColors.surfaceHighest,
      surfaceContainerHighest: VgColors.surfaceOverlay,
      inverseSurface: VgColors.ink,
      onInverseSurface: VgColors.surface,
      inversePrimary: VgColors.accentDeep,
    );
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: VgColors.surface,
      canvasColor: VgColors.surface,
      splashFactory: InkSparkle.splashFactory,
    );
  }

  static ThemeData _lightBase() {
    const scheme = ColorScheme.light(
      primary: VgColors.lightAccent,
      onPrimary: Colors.white,
      secondary: Color(0xFF2F6B4A),
      onSecondary: Colors.white,
      tertiary: Color(0xFF7A5A12),
      onTertiary: Colors.white,
      error: Color(0xFFC0392B),
      onError: Colors.white,
      surface: VgColors.lightSurface,
      onSurface: VgColors.lightInk,
      onSurfaceVariant: VgColors.lightInkMuted,
      outline: VgColors.lightLine,
      outlineVariant: VgColors.lightLineStrong,
      surfaceContainerLowest: Colors.white,
      surfaceContainerLow: VgColors.lightSurfaceRaised,
      surfaceContainer: VgColors.lightSurfaceHigh,
      surfaceContainerHigh: VgColors.lightSurfaceHighest,
      surfaceContainerHighest: Color(0xFFDFE9E3),
      inverseSurface: VgColors.lightInk,
      onInverseSurface: Colors.white,
      inversePrimary: VgColors.accent,
    );
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: scheme,
      scaffoldBackgroundColor: VgColors.lightSurface,
      canvasColor: VgColors.lightSurface,
      splashFactory: InkSparkle.splashFactory,
    );
  }

  static ThemeData _apply(ThemeData base, String animationLevel) =>
      applyThemeData(base, animationLevel);
}
