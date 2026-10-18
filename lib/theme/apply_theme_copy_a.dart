part of 'app_theme.dart';

ThemeData applyThemeCopyA(
  ThemeData base,
  TextTheme text,
  ColorScheme scheme,
  Color ink,
  Color muted,
  Color line,
) {
  return base.copyWith(
    textTheme: text,
    primaryTextTheme: text,    cardTheme: CardThemeData(
      color: scheme.surfaceContainerLow,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(VgRadius.lg),
      ),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      foregroundColor: ink,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: text.titleLarge,
    ),
    dividerTheme: DividerThemeData(color: line, space: 1, thickness: 1),
    iconTheme: IconThemeData(color: muted, size: VgIcon.md),
    listTileTheme: ListTileThemeData(
      iconColor: muted,
      titleTextStyle: text.titleMedium,
      subtitleTextStyle: text.bodyMedium,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(VgRadius.md),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      height: 68,
      indicatorColor: scheme.primary.withValues(alpha: 0.16),
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      labelTextStyle: WidgetStatePropertyAll(text.labelMedium),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: Colors.transparent,
      indicatorColor: scheme.primary.withValues(alpha: 0.16),
      elevation: 0,
      labelType: NavigationRailLabelType.all,
      // The selected icon sits on a *tinted* indicator, not a filled
      // primary surface, so it takes `primary` — not `onPrimary`.
      // `onPrimary` is near-black and would be black-on-near-white in
      // the light theme's indicator.
      selectedIconTheme: IconThemeData(color: scheme.primary),
      unselectedIconTheme: IconThemeData(color: muted),
      selectedLabelTextStyle: text.labelMedium?.copyWith(color: ink),
      unselectedLabelTextStyle: text.labelMedium,
    ),
  );
}
