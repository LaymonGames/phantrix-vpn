import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:phantrix/theme/app_theme.dart';
import 'package:phantrix/theme/tokens.dart';

/// WCAG 2.2 relative luminance.
///
/// `Color.r/.g/.b` are already 0-1 doubles, which is exactly the range the
/// WCAG formula expects, so they are used directly (the deprecated
/// 0-255 `.red/.green/.blue` int getters would also need a /255).
double _luminance(Color c) {
	double lin(double channel) =>
		channel <= 0.03928 ? channel / 12.92 : math.pow((channel + 0.055) / 1.055, 2.4).toDouble();
	return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b);
}

/// WCAG contrast ratio between two opaque colours.
double _contrast(Color a, Color b) {
	final la = _luminance(a), lb = _luminance(b);
	final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
	return (hi + 0.05) / (lo + 0.05);
}

void main() {
	// WCAG 2.2 AA: 4.5:1 for ordinary text, 3:1 for large text (>=18.66px bold
	// or >=24px) and for non-text boundaries such as icons and indicators.
	const aaBody = 4.5;
	const aaLarge = 3.0;

	for (final themeCase in <(String, ThemeData)>[
		('light', AppTheme.light(animationLevel: 'none')),
		('dark', AppTheme.dark(animationLevel: 'none')),
	]) {
		group('${themeCase.$1} theme contrast', () {
			final scheme = themeCase.$2.colorScheme;

			test('body ink on the scaffold surfaces meets AA body text', () {
				expect(
					_contrast(scheme.onSurface, scheme.surface),
					greaterThanOrEqualTo(aaBody),
				);
				expect(
					_contrast(scheme.onSurface, scheme.surfaceContainerLow),
					greaterThanOrEqualTo(aaBody),
				);
			});

			test('muted ink (labels, subtitles) meets AA body text', () {
				expect(
					_contrast(scheme.onSurfaceVariant, scheme.surface),
					greaterThanOrEqualTo(aaBody),
				);
				expect(
					_contrast(scheme.onSurfaceVariant, scheme.surfaceContainerLow),
					greaterThanOrEqualTo(aaBody),
				);
			});

			test('a filled button label meets AA on the primary fill', () {
				expect(_contrast(scheme.onPrimary, scheme.primary), greaterThanOrEqualTo(aaBody));
			});

			test('a tonal button label meets AA on the secondary fill', () {
				expect(
					_contrast(scheme.onSecondary, scheme.secondary),
					greaterThanOrEqualTo(aaBody),
				);
			});

			test('an error button label meets AA on the error fill', () {
				expect(_contrast(scheme.onError, scheme.error), greaterThanOrEqualTo(aaBody));
			});

			test('a text button (primary-coloured) meets AA on every surface', () {
				// TextButton has no fill: its label colour is `primary` and it
				// sits on the surface, so the pair must clear AA on its own.
				expect(_contrast(scheme.primary, scheme.surface), greaterThanOrEqualTo(aaBody));
				expect(
					_contrast(scheme.primary, scheme.surfaceContainerLow),
					greaterThanOrEqualTo(aaBody),
				);
			});

			test('the selected navigation icon reads on the tinted indicator', () {
				// The rail/bar indicator is `secondary` at 16% over the surface;
				// the selected icon is `secondary`. Composite the indicator over
				// the surface and require the icon to stay readable on it — this
				// is the exact pair that used to be white-on-near-white.
				final indicator = Color.alphaBlend(
					scheme.secondary.withValues(alpha: 0.16),
					scheme.surface,
				);
				expect(_contrast(scheme.secondary, indicator), greaterThanOrEqualTo(aaLarge));
			});

			test('the unselected navigation icon reads on the surface', () {
				expect(
					_contrast(scheme.onSurfaceVariant, scheme.surfaceContainerLow),
					greaterThanOrEqualTo(aaLarge),
				);
			});

			test('the disabled-button exception still reads as disabled but visible', () {
				// Disabled controls follow the accessibility exception, but their
				// state must remain understandable: the disabled label must be
				// distinguishable from the surface it sits on.
				expect(
					_contrast(scheme.onSurface.withValues(alpha: 0.38), scheme.surface),
					greaterThanOrEqualTo(1.6),
				);
			});
		});
	}

	group('state colours', () {
		test('the connected green reads as a non-text accent on the surface', () {
			// The connected green is used for chips, dots, indicators and the orb
			// rim — non-text, so the AA target is 3:1, not the body-text 4.5:1.
			for (final surface in [
				VgColors.surface,
				VgColors.surfaceRaised,
				VgColors.surfaceHigh,
			]) {
				expect(_contrast(VgColors.connected, surface), greaterThanOrEqualTo(aaLarge),
					reason: 'connected green on $surface');
			}
		});

		test('the orb error fill carries a readable large label', () {
			// The orb label is display-scale text (>=24px), so the AA large-text
			// target of 3:1 is the correct bar, not 4.5:1.
			expect(_contrast(Colors.white, const Color(0xFF8C2F2F)), greaterThanOrEqualTo(aaLarge));
			expect(_contrast(Colors.white, const Color(0xFF2A4595)), greaterThanOrEqualTo(aaLarge));
		});

		test('the orb blocked fill carries a readable dark label', () {
			expect(
				_contrast(const Color(0xFF231900), const Color(0xFF8C6415)),
				greaterThanOrEqualTo(aaLarge),
			);
		});
	});
}
