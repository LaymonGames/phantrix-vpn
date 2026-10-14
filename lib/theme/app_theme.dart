import 'package:flutter/material.dart';

import 'tokens.dart';

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

	static ThemeData _apply(ThemeData base, String animationLevel) {
		final scheme = base.colorScheme;
		final isDark = base.brightness == Brightness.dark;
		final ink = scheme.onSurface;
		final muted = scheme.onSurfaceVariant;
		final line = scheme.outline;
		final tint = isDark ? Colors.black : const Color(0xFF1E3A2B);

		final text = base.textTheme
				.apply(
					bodyColor: ink,
					displayColor: ink,
					fontFamily: 'Inter',
				)
				.copyWith(
					displayLarge: _style(52, FontWeight.w700, ink, height: 1.06, spacing: -1.4),
					displayMedium: _style(40, FontWeight.w700, ink, height: 1.1, spacing: -1.0),
					displaySmall: _style(32, FontWeight.w600, ink, height: 1.16, spacing: -0.6),
					headlineMedium: _style(26, FontWeight.w600, ink, height: 1.22, spacing: -0.4),
					headlineSmall: _style(21, FontWeight.w600, ink, height: 1.28, spacing: -0.2),
					titleLarge: _style(17, FontWeight.w600, ink, height: 1.32, spacing: -0.1),
					titleMedium: _style(15, FontWeight.w600, ink, height: 1.36),
					titleSmall: _style(13.5, FontWeight.w600, muted, height: 1.4),
					bodyLarge: _style(15, FontWeight.w400, ink, height: 1.5),
					bodyMedium: _style(13.5, FontWeight.w400, muted, height: 1.55),
					bodySmall: _style(12.5, FontWeight.w400, muted, height: 1.5),
					labelLarge: _style(14, FontWeight.w600, ink, height: 1.2, spacing: 0.1),
					labelMedium: _style(12.5, FontWeight.w600, muted, height: 1.2, spacing: 0.2),
					labelSmall: _style(11.5, FontWeight.w700, muted, height: 1.2, spacing: 0.6),
				)
				.apply(fontFamily: 'Inter', fontFamilyFallback: VgType.sans);

		return base.copyWith(
			textTheme: text,
			primaryTextTheme: text,
			cardTheme: CardThemeData(
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
			chipTheme: ChipThemeData(
				backgroundColor: scheme.surfaceContainerHigh,
				side: BorderSide(color: line),
				shape: RoundedRectangleBorder(
					borderRadius: BorderRadius.circular(VgRadius.pill),
				),
				labelStyle: text.labelMedium ?? const TextStyle(),
				padding: const EdgeInsets.symmetric(horizontal: VgSpace.sm, vertical: VgSpace.xs),
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
					(s) =>
						s.contains(WidgetState.selected)
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
					borderRadius: BorderRadius.vertical(
						top: Radius.circular(VgRadius.xl),
					),
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

	static TextStyle _style(
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
}

class _NoTransitions extends PageTransitionsBuilder {
	const _NoTransitions();

	@override
	Widget buildTransitions<T>(
		PageRoute<T>? route,
		BuildContext? context,
		Animation<double> animation,
		Animation<double>? secondaryAnimation,
		Widget child,
	) =>
			child;
}

class _FadeRise extends PageTransitionsBuilder {
	const _FadeRise();

	@override
	Widget buildTransitions<T>(
		PageRoute<T>? route,
		BuildContext? context,
		Animation<double> animation,
		Animation<double>? secondaryAnimation,
		Widget child,
	) {
		final curved = CurvedAnimation(
			parent: animation,
			curve: VgMotion.emphasised,
			reverseCurve: VgMotion.exit,
		);
		return FadeTransition(
			opacity: curved,
			child: SlideTransition(
				position: Tween<Offset>(
					begin: const Offset(0, 0.02),
					end: Offset.zero,
				).animate(curved),
				child: child,
			),
		);
	}
}

/// A dark scrim used behind the orb, so the glow has something to sit on.
///
/// A radial gradient rather than a flat colour: a flat one makes the orb look
/// like a sticker, and the gradient gives the impression of light in the
/// middle of the screen.
class AmbientGlow extends StatelessWidget {
	const AmbientGlow({required this.color, required this.intensity, super.key});

	final Color color;

	/// 0 for hidden, 1 at full strength.
	final double intensity;

	@override
	Widget build(BuildContext context) {
		if (intensity <= 0.01) {
			return const SizedBox.shrink();
		}
		return IgnorePointer(
			child: DecoratedBox(
				decoration: BoxDecoration(
					gradient: RadialGradient(
						center: const Alignment(0, -0.25),
						radius: 0.95,
						colors: [
							color.withValues(alpha: 0.22 * intensity),
							color.withValues(alpha: 0.0),
						],
						stops: const [0.0, 0.72],
					),
				),
			),
		);
	}
}

/// Applies the ambient glow behind a scaffold body.
class VgScaffold extends StatelessWidget {
	const VgScaffold({
		required this.child,
		this.glowColor,
		this.glowIntensity = 0,
		this.destinations,
		required this.title,
		super.key,
	});

	final Widget child;

	/// Colour of the ambient light, normally the current state colour.
	final Color? glowColor;
	final double glowIntensity;

	/// Set on the widest layouts only; the shell supplies the navigation.
	final List<Widget>? destinations;

	final String title;

	@override
	Widget build(BuildContext context) {
		return Stack(
			fit: StackFit.expand,
			children: [
				if (glowColor != null && glowIntensity > 0.01)
					AmbientGlow(color: glowColor!, intensity: glowIntensity),
				SafeArea(child: child),
			],
		);
	}
}