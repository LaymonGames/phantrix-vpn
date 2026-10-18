part of 'app_theme.dart';

ThemeData applyThemeCopyB(
  ThemeData base,
  TextTheme text,
  ColorScheme scheme,
  Color ink,
  Color muted,
  Color line,
  Color tint,
  String animationLevel,
) {
  return base.copyWith(
    chipTheme: ChipThemeData(
      backgroundColor: scheme.surfaceContainerHigh,
      side: BorderSide(color: line),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(VgRadius.pill),
      ),
      labelStyle: text.labelMedium ?? const TextStyle(),
      padding: const EdgeInsets.symmetric(
        horizontal: VgSpace.sm,
        vertical: VgSpace.xs,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 48),
        padding: const EdgeInsets.symmetric(horizontal: VgSpace.xl),
        textStyle: text.labelLarge,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(VgRadius.md),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 48),
        padding: const EdgeInsets.symmetric(horizontal: VgSpace.lg),
        foregroundColor: ink,
        side: BorderSide(color: line),
        textStyle: text.labelLarge,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(VgRadius.md),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 44),
        textStyle: text.labelLarge,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(VgRadius.sm),
        ),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        // 44 is the smallest comfortable touch target on both
        // platforms; going below it is what makes a desktop app
        // feel broken on a laptop trackpad.
        minimumSize: const Size(44, 44),
        foregroundColor: muted,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHigh,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: VgSpace.md,
        vertical: VgSpace.md,
      ),
      hintStyle: text.bodyMedium,
      labelStyle: text.bodyMedium,
      // A visible, consistent focus ring: the app is full of
      // interactive elements and keyboard users must be able to see
      // where they are.
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(VgRadius.md),
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(VgRadius.md),
        borderSide: BorderSide(color: line),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(VgRadius.md),
        borderSide: BorderSide(color: scheme.error),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(VgRadius.md),
        borderSide: BorderSide(color: scheme.error, width: 2),
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(VgRadius.md),
        borderSide: BorderSide(color: line),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? scheme.onPrimary : muted,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected)
            ? scheme.primary
            : scheme.surfaceContainerHighest,
      ),
      trackOutlineColor: WidgetStatePropertyAll(line),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: scheme.primary,
      inactiveTrackColor: scheme.surfaceContainerHighest,
      thumbColor: scheme.primary,
      overlayColor: scheme.primary.withValues(alpha: 0.12),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(VgRadius.xl),
      ),
      titleTextStyle: text.titleLarge,
      contentTextStyle: text.bodyMedium,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(VgRadius.xl)),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: scheme.surfaceContainerHighest,
      contentTextStyle: text.bodyMedium?.copyWith(color: ink),
      actionTextColor: scheme.primary,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(VgRadius.md),
      ),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(VgRadius.sm),
      ),
      textStyle: text.bodySmall?.copyWith(color: ink),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: scheme.primary,
      linearTrackColor: scheme.surfaceContainerHighest,
      circularTrackColor: scheme.surfaceContainerHighest,
    ),
    // A visible scrollbar on a desktop window. The default overlay
    // scrollbar is invisible until the pointer happens to be over the
    // content, which on a dashboard that scrolls looks like a screen
    // that has ended.
    scrollbarTheme: ScrollbarThemeData(
      thickness: const WidgetStatePropertyAll(8),
      radius: const Radius.circular(4),
      thumbColor: WidgetStatePropertyAll(
        scheme.onSurfaceVariant.withValues(alpha: 0.28),
      ),
      trackVisibility: const WidgetStatePropertyAll(false),
    ),
    shadowColor: tint,
    splashColor: scheme.primary.withValues(alpha: 0.08),
    highlightColor: scheme.primary.withValues(alpha: 0.04),
    pageTransitionsTheme: animationLevel == 'none'
        ? const PageTransitionsTheme(
            builders: {
              TargetPlatform.android: _NoTransitions(),
              TargetPlatform.linux: _NoTransitions(),
              TargetPlatform.windows: _NoTransitions(),
            },
          )
        : const PageTransitionsTheme(
            builders: {
              // A shared fade-and-rise rather than the platform
              // default, because the default on desktop is a
              // horizontal slide that fights a vertical
              // content change.
              TargetPlatform.android: _FadeRise(),
              TargetPlatform.linux: _FadeRise(),
              TargetPlatform.windows: _FadeRise(),
            },
          ),
  );
}
