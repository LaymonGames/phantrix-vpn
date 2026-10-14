import 'package:flutter/material.dart';

/// The Phantrix design system.
///
/// Everything visual is a named value here. A screen that reaches for
/// `Color(0xFF...)` or `EdgeInsets.all(12)` directly is a screen that will
/// drift from the rest of the app, so the tokens exist to make that the
/// awkward option rather than the easy one.
///
/// ## The visual idea
///
/// A VPN client is a security tool, and security tools that look like toys
/// are not trusted. So the palette is near-neutral and very dark, one
/// restrained accent, and colour is spent almost entirely on *state* — which
/// means the one green thing on screen is genuinely telling you something.
///
/// Two rules keep it honest:
///
/// 1. **Accent and state stay distinguishable.** The brand accent is a clear
///    green (the colour of the app icon) and means "this is selected or
///    interactive". The connected state is a cooler emerald-teal, and every
///    state also carries its own icon and label, so a selected row and a live
///    tunnel are never told apart by hue alone.
/// 2. **Depth comes from layered surfaces, not from outlines.** Five surface
///    steps let a card, an inset well, a chip and a hover state each have
///    their own level, and a single soft light source sits at the top left.
///
/// Status is never carried by colour alone. Every state also has a distinct
/// icon and a distinct label, which is what makes it readable for a
/// colour-blind user and in a screenshot printed in greyscale.
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

/// Spacing.
///
/// A 4pt base grid. Named rather than literal because a literal `16` in one
/// place and a literal `15` in another is invisible in review and obvious on
/// screen.
class VgSpace {
	VgSpace._();

	static const double xxs = 2;
	static const double xs = 4;
	static const double sm = 8;
	static const double md = 12;
	static const double lg = 16;
	static const double xl = 24;
	static const double xxl = 32;
	static const double xxxl = 48;

	/// The page gutter. Wider on a large window so a line of text never
	/// becomes uncomfortably long.
	static double gutter(double width) {
		if (width >= 1000) {
			return xxl;
		}
		if (width >= 700) {
			return xl;
		}
		return lg;
	}

	/// The widest a single column of reading content may become.
	///
	/// Long measures are hard to read. Capping the column is what keeps a
	/// windowed app looking composed on a 4K display instead of stretched.
	/// This is the cap for one-column screens — settings, licences, privacy —
	/// where a single measure of text is the whole layout.
	static const double maxContentWidth = 680;

	/// The widest a multi-column layout may become.
	///
	/// Two-column screens (the dashboard) are not a measure of text; they are
	/// a dashboard, so they are allowed to be wider before they start to
	/// stretch. They still stop, because an unbounded dashboard on a 4K
	/// display reads as a browser window that lost the plot.
	static const double maxDashboardWidth = 1160;

	/// Vertical rhythm between two sibling panels on a wide screen.
	static const double columnGap = 20;
}

/// The width breakpoints the shell and screens switch on.
///
/// Named rather than scattered literals, because a screen that guesses at a
/// width is a screen that disagrees with the shell about what a phone is.
class VgBreakpoints {
	VgBreakpoints._();

	/// At or above this the app uses the desktop sidebar.
	static const double sidebar = 900;

	/// At or above this the dashboard may use two columns.
	static const double twoColumn = 1000;

	/// At or above this the servers screen may use a wider measure.
	static const double wideMeasure = 1100;
}

/// Corner radii.
class VgRadius {
	VgRadius._();

	static const double sm = 8;
	static const double md = 12;
	static const double lg = 16;
	static const double xl = 22;
	static const double pill = 999;
}

/// Icon sizes.
///
/// Icons in this app carry state, so their sizes are part of the system rather
/// than a number each screen invents. Three sizes, each with a job.
class VgIcon {
	VgIcon._();

	/// Inline with body text. The default.
	static const double sm = 16;

	/// In a list row or a button. The workhorse.
	static const double md = 20;

	/// A screen's single hero icon.
	static const double lg = 28;
}

/// Motion.
///
/// Every duration is short. A VPN client spends its animation budget showing
/// *state changing*, and a slow animation on a connect button reads as the app
/// being unsure rather than as polish.
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

/// Elevation.
///
/// Shadows only, never borders, for the large surfaces. A border on a card
/// plus a shadow gives the "grey box" look; a shadow alone, tinted with the
/// surface colour rather than black, gives depth without the outline.
class VgShadow {
	VgShadow._();

	static List<BoxShadow> forCard(Color tint) => [
		BoxShadow(
			color: tint.withValues(alpha: 0.5),
			blurRadius: 24,
			offset: const Offset(0, 8),
			spreadRadius: -8,
		),
	];

	static List<BoxShadow> forLifted(Color tint, {double strength = 0.62}) => [
		BoxShadow(
			color: tint.withValues(alpha: strength),
			blurRadius: 48,
			offset: const Offset(0, 20),
			spreadRadius: -12,
		),
	];

	/// The shadow under the desktop sidebar.
	///
	/// Separate from [forCard] because a sidebar is full-height: it needs to
	/// separate from the content beside it rather than lift off the floor.
	static List<BoxShadow> forSidebar(Color tint) => [
		BoxShadow(
			color: tint.withValues(alpha: 0.55),
			blurRadius: 32,
			offset: const Offset(8, 0),
			spreadRadius: -12,
		),
	];
}

/// Font stacks.
///
/// No web fonts are bundled: a VPN client that has to reach a CDN before it can
/// draw a button is a VPN client that shows nothing on a bad connection, which
/// is the one situation where the user most needs it. These are platform
/// stacks, so each OS renders with its own typeface and nothing is downloaded.
class VgType {
	VgType._();

	static const List<String> sans = <String>[
		'Inter',
		'Segoe UI Variable Display',
		'Segoe UI',
		'Roboto',
		'Helvetica Neue',
		'system-ui',
	];

	static const List<String> mono = <String>[
		'Cascadia Code',
		'JetBrains Mono',
		'SF Mono',
		'Menlo',
		'Consolas',
		'monospace',
	];

	/// Tabular figures for anything that counts.
	///
	/// A session timer that jitters in width as the digits change looks broken;
	/// tabular figures are what stop that.
	static const List<FontFeature> tabular = [FontFeature.tabularFigures()];
}