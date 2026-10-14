import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import 'status_style.dart';

/// The primary connect control.
///
/// ## What it shows, and what it deliberately does not
///
/// The ring is the honest part. It shows a measured fraction only when a caller
/// has a real quantity to report; otherwise it uses a travelling arc while the
/// engine is working. It never turns elapsed time into fake progress, and it
/// never shows a completed ring unless the tunnel is genuinely verified.
///
/// When the tunnel is up, the orb reports *tunnel established*. It does not
/// claim the user's traffic is protected on its own: that claim belongs to the
/// state machine, which requires a fresh handshake and a changed public address
/// before it will say "connected", and the label here is derived from the same
/// state so the two cannot disagree.
///
/// ## Motion
///
/// Every animation is suppressed when the user has asked for reduced motion,
/// because a pulsing element that fills a large part of the screen is exactly
/// what that setting exists for. The state is still fully legible without it —
/// colour, icon and label all carry it.
class ConnectionOrb extends StatefulWidget {
	const ConnectionOrb({
		required this.state,
		required this.onPressed,
		this.enabled = true,
		this.progress,
		this.reducedMotion = false,
		this.size = 220,
		super.key,
	});

	final VgTone state;
	final VoidCallback? onPressed;
	final bool enabled;

	/// A 0..1 quantity, or null when there is nothing to measure.
	///
	/// Only meaningful for [VgTone.working] when the caller has a measurable
	/// quantity. Null makes the ring indeterminate instead of fabricating a
	/// percentage from elapsed connection time.
	final double? progress;

	final bool reducedMotion;
	final double size;

	@override
	State<ConnectionOrb> createState() => _ConnectionOrbState();
}

class _ConnectionOrbState extends State<ConnectionOrb>
		with SingleTickerProviderStateMixin {
	late final AnimationController _pulse = AnimationController(
		vsync: this,
		duration: widget.reducedMotion ? VgMotion.slow : VgMotion.orbit,
	);

	/// Whether anything on this orb is actually moving.
	///
	/// An animation that runs forever on a screen showing nothing happening is
	/// not just untidy: it never lets the frame scheduler go idle, so it costs
	/// battery on a screen that is doing nothing, and it makes any test that
	/// waits for the UI to settle time out. The orb therefore only animates
	/// while a connection is genuinely in progress and no measurable
	/// completion fraction is available.
	bool get _animates =>
		!widget.reducedMotion &&
		widget.state == VgTone.working &&
		widget.progress == null;

	@override
	void initState() {
		super.initState();
		_syncAnimation();
	}

	@override
	void didUpdateWidget(covariant ConnectionOrb oldWidget) {
		super.didUpdateWidget(oldWidget);
		if (oldWidget.reducedMotion != widget.reducedMotion) {
			_pulse.duration = widget.reducedMotion ? VgMotion.slow : VgMotion.orbit;
		}
		if (oldWidget.state != widget.state) {
			// Each phase starts at its canonical position rather than inheriting a
			// half-finished connecting sweep.
			_pulse.stop();
			_pulse.value = 0;
		}
		_syncAnimation();
	}

	void _syncAnimation() {
		if (_animates) {
			if (!_pulse.isAnimating) {
				_pulse.repeat();
			}
		} else if (_pulse.isAnimating) {
			// Stopped rather than paused, so a screen showing a static state
			// schedules no frames at all.
			_pulse.stop();
			_pulse.value = 0;
		}
	}

	@override
	void dispose() {
		_pulse.dispose();
		super.dispose();
	}

	@override
	Widget build(BuildContext context) {
		final theme = Theme.of(context);
		final palette = OrbPalette.forTone(widget.state, theme);
		final busy = widget.state == VgTone.working;

		return Semantics(
			button: true,
			enabled: widget.enabled,
			label: palette.semanticLabel,
			hint: palette.hint,
			child: Tooltip(
				message: palette.action,
				child: AnimatedOpacity(
					// A disabled control dims rather than disappears: the user
					// can still see what the button would do.
					duration: VgMotion.fast,
					opacity: widget.enabled ? 1 : 0.45,
					child: MouseRegion(
						cursor: widget.enabled
								? SystemMouseCursors.click
								: SystemMouseCursors.basic,
						child: GestureDetector(
							onTap: widget.enabled ? widget.onPressed : null,
							child: Semantics(
								excludeSemantics: true,
								child: SizedBox(
									width: widget.size,
									height: widget.size,
									child: Stack(
										alignment: Alignment.center,
										children: [
											// Bloom sits behind the ring and gives the orb depth.
											if (!widget.reducedMotion && widget.state != VgTone.idle)
												AnimatedBuilder(
													animation: _pulse,
													builder: (context, _) => _Bloom(
														color: palette.colors.accent,
														strength: _bloomStrength(),
														size: widget.size * 1.36,
													),
												),
											_Track(color: palette.track, size: widget.size),
											_Ring(
												color: palette.colors.accent,
												progress: widget.progress,
												// The indeterminate arc is a *travelling* arc,
												// and a frozen arc is a claim the app
												// cannot support: a quarter-drawn ring says
												// "a quarter done", and nothing here knows
												// that. Under reduced motion the ring falls
												// back to the bare track, so "connecting" is
												// carried by the colour, the glyph and the
												// label instead — which is what that
												// setting is for.
												pulsing:
														busy &&
														widget.progress == null &&
														!widget.reducedMotion,
												complete: widget.state == VgTone.connected,
												size: widget.size,
												animation: _pulse,
											),
											_Face(
												color: palette.colors.face,
												edge: palette.colors.accent,
												state: widget.state,
												size: widget.size * 0.78,
											),
											_Identity(
												color: palette.colors.accent,
												icon: palette.colors.icon,
												title: palette.title,
												subtitle: palette.subtitle,
											),
										],
									),
								),
							),
						),
					),
				),
			),
		);
	}

	double _bloomStrength() {
		// Connected glows steadily; working breathes. Idle and failed do not
		// glow, because a glow reads as "active" and neither of those is.
		return switch (widget.state) {
			VgTone.connected => 0.55,
			VgTone.working =>
				0.25 + 0.35 * (0.5 + 0.5 * math.sin(_pulse.value * 2 * math.pi)),
			_ => 0,
		};
	}
}

/// The wording the orb shows for a tone.
///
/// Split from the colours so the two can be read independently: the colours
/// come from [VgStatusColors], which every other surface in the app also uses,
/// and only this control needs a title, a subtitle and a sentence for a screen
/// reader.
class OrbPalette {
	const OrbPalette({
		required this.colors,
		required this.track,
		required this.title,
		required this.subtitle,
		required this.action,
		required this.semanticLabel,
		required this.hint,
	});

	final VgStatusColors colors;

	/// The ring's resting colour.
	///
	/// Derived from the theme rather than the status colours: an *unfilled*
	/// ring wants the neutral one, because a ring that is already the accent
	/// colour would claim the state the fill is there to show.
	final Color track;

	final String title;
	final String subtitle;
	final String action;
	final String semanticLabel;

	/// What a screen reader says the gesture will do.
	///
	/// Phrased per tone rather than derived from [action], because the verb
	/// alone does not always make a sentence: "cancel the VPN" is not what
	/// cancelling does, and an action that has changed from *starting* to
	/// *stopping* must say so before the user presses it.
	final String hint;

	static OrbPalette forTone(VgTone tone, ThemeData theme) {
		final colors = VgStatusColors.of(tone, theme.brightness);
		final track = theme.brightness == Brightness.dark
				? VgColors.surfaceHighest
				: VgColors.lightLine;
		return switch (tone) {
			VgTone.idle => OrbPalette(
				colors: colors,
				track: track,
				title: 'Disconnected',
				subtitle: 'Tap to connect',
				action: 'Connect',
				semanticLabel: 'Disconnected. Activate to connect the VPN.',
				hint: 'Double tap to connect the VPN',
			),
			VgTone.working => OrbPalette(
				colors: colors,
				track: track,
				title: 'Connecting',
				subtitle: 'Tap to cancel',
				action: 'Cancel',
				semanticLabel: 'Connecting. Activate to cancel the connection attempt.',
				hint: 'Double tap to cancel the connection attempt',
			),
			VgTone.connected => OrbPalette(
				colors: colors,
				track: track,
				title: 'Connected',
				subtitle: 'Tunnel established',
				action: 'Disconnect',
				semanticLabel:
					'Connected. The tunnel is established and your traffic is routed through it.',
				hint: 'Double tap to disconnect the VPN',
			),
			VgTone.failed => OrbPalette(
				colors: colors,
				track: track,
				title: 'Not connected',
				subtitle: 'Tap to try again',
				action: 'Retry',
				semanticLabel: 'Not connected. Activate to try again.',
				hint: 'Double tap to try again',
			),
			VgTone.blocked => OrbPalette(
				colors: colors,
				track: track,
				title: 'Needs attention',
				subtitle: 'Tap for details',
				action: 'Review',
				semanticLabel: 'Needs your attention before it can connect.',
				hint: 'Double tap to see what is needed',
			),
		};
	}
}

class _Bloom extends StatelessWidget {
	const _Bloom({required this.color, required this.strength, required this.size});

	final Color color;
	final double strength;
	final double size;

	@override
	Widget build(BuildContext context) {
		return Container(
			width: size,
			height: size,
			decoration: BoxDecoration(
				shape: BoxShape.circle,
				gradient: RadialGradient(
					colors: [
						color.withValues(alpha: 0.20 * strength),
						color.withValues(alpha: 0.0),
					],
					stops: const [0.35, 1.0],
				),
			),
		);
	}
}

class _Track extends StatelessWidget {
	const _Track({required this.color, required this.size});

	final Color color;
	final double size;

	@override
	Widget build(BuildContext context) {
		return Container(
			width: size,
			height: size,
			decoration: BoxDecoration(
				shape: BoxShape.circle,
				border: Border.all(color: color, width: 2),
			),
		);
	}
}

/// The arc. Drawn rather than composed from a progress indicator so that the
/// stroke can taper, which is what makes it read as a hand-drawn sweep rather
/// than a machine spinner.
class _Ring extends StatelessWidget {
	const _Ring({
		required this.color,
		required this.progress,
		required this.pulsing,
		required this.complete,
		required this.size,
		required this.animation,
	});

	final Color color;
	final double? progress;
	final bool pulsing;
	final bool complete;
	final double size;
	final Animation<double> animation;

	@override
	Widget build(BuildContext context) {
		return SizedBox(
			width: size,
			height: size,
			child: AnimatedBuilder(
				animation: animation,
				builder: (context, _) {
					// The value is read here rather than taken from the builder's
					// second argument: `AnimatedBuilder`'s builder receives the
					// child widget, not the animation's value.
					final phase = animation.value;
					return CustomPaint(
						painter: _RingPainter(
							color: color,
							progress: progress,
							complete: complete,
							sweep: pulsing
									? (0.30 + 0.18 * (0.5 - 0.5 * math.cos(phase * 2 * math.pi)))
									: null,
							phase: phase,
						),
					);
				},
			),
		);
	}
}

class _RingPainter extends CustomPainter {
	_RingPainter({
		required this.color,
		required this.progress,
		required this.complete,
		required this.sweep,
		required this.phase,
	});

	final Color color;

	/// A fixed 0..1 fraction, or null.
	final double? progress;

	/// Whether the tunnel has been confirmed connected. Only this state draws
	/// the solid completion ring.
	final bool complete;

	/// A fixed sweep fraction for the indeterminate case, or null.
	final double? sweep;

	/// The animation value at paint time. Carried on the painter so that
	/// `shouldRepaint` can compare it — otherwise the travelling arc would be
	/// painted once and then never again.
	final double phase;

	static const double _startAngle = -math.pi / 2;
	static const double _gap = 0.10;

	@override
	void paint(Canvas canvas, Size size) {
		final rect = Offset.zero & size;
		final centre = rect.center;
		final radius = size.width / 2 - 6;

		final paint = Paint()
			..style = PaintingStyle.stroke
			..strokeWidth = 4
			..strokeCap = StrokeCap.round;

		if (complete) {
			// Connected: a closed ring. A full circle is the one shape that
			// unambiguously means "complete", which is why it is reserved for the
			// only state that is genuinely complete.
			paint.color = color;
			canvas.drawCircle(centre, radius, paint);
			// A second, dimmer ring outside it gives the impression of depth
			// without adding another moving element.
			paint
				..color = color.withValues(alpha: 0.18)
				..strokeWidth = 10;
			canvas.drawCircle(centre, radius + 6, paint);
			return;
		}

		if (sweep != null) {
			// Indeterminate: a travelling arc with a soft head, which reads as
			// "working" without pretending to know how much is left. The
			// rotation is taken from the animation phase, which is what makes it
			// travel rather than merely breathe.
			final sweepAngle = sweep! * 2 * math.pi;
			final start = _startAngle + phase * 2 * math.pi;
			final rect2 = Rect.fromCircle(center: centre, radius: radius);
			paint
				..color = color.withValues(alpha: 0.22)
				..strokeWidth = 9;
			canvas.drawArc(rect2, start, sweepAngle, false, paint);
			paint
				..color = color
				..strokeWidth = 4;
			canvas.drawArc(rect2, start, sweepAngle, false, paint);
			return;
		}

		if (progress == null) {
			// Idle, failed and blocked states use only the underlying track; a
			// solid foreground ring is reserved for a confirmed connection.
			return;
		}

		// Determinate: the measured fraction, with the remainder drawn faintly
		// so the track and the fill are one object rather than two.
		final fraction = progress!.clamp(0.0, 1.0);
		final rect2 = Rect.fromCircle(center: centre, radius: radius);
		paint
			..color = color.withValues(alpha: 0.14)
			..strokeWidth = 4;
		canvas.drawArc(rect2, _startAngle + _gap, 2 * math.pi - _gap * 2, false, paint);
		paint.color = color;
		canvas.drawArc(
			rect2,
			_startAngle + _gap,
			(2 * math.pi - _gap * 2) * fraction,
			false,
			paint,
		);
	}

	@override
	bool shouldRepaint(covariant _RingPainter old) =>
			old.progress != progress ||
			old.complete != complete ||
			old.sweep != sweep ||
			old.color != color ||
			// Only re-compare the phase when something is actually animating;
			// otherwise a static ring would request a repaint on every frame.
			(sweep != null && old.phase != phase);
}

class _Face extends StatelessWidget {
	const _Face({
		required this.color,
		required this.edge,
		required this.state,
		required this.size,
	});

	final Color color;
	final Color edge;
	final VgTone state;
	final double size;

	@override
	Widget build(BuildContext context) {
		final isDark = Theme.of(context).brightness == Brightness.dark;
		return AnimatedContainer(
			duration: VgMotion.normal,
			curve: VgMotion.emphasised,
			width: size,
			height: size,
			decoration: BoxDecoration(
				shape: BoxShape.circle,
				gradient: LinearGradient(
					begin: Alignment.topLeft,
					end: Alignment.bottomRight,
					colors: [
						Color.lerp(color, Colors.white, isDark ? 0.07 : 0.55)!,
						color,
					],
				),
				border: Border.all(
					color: edge.withValues(alpha: state == VgTone.idle ? 0.12 : 0.30),
					width: 1.5,
				),
				boxShadow: VgShadow.forLifted(
					isDark ? Colors.black : const Color(0xFF1E3A2B),
					// Much lighter in the light theme. The same strength that
					// reads as a soft lift under a near-black face reads as a
					// grey disc under a pale one, because there is nothing above
					// it for the shadow to be darker *than*.
					strength: isDark ? 0.62 : 0.28,
				),
			),
		);
	}
}

/// The glyph, the state name and the one-line explanation, stacked.
///
/// A shape as well as a colour: the state must be readable in a greyscale
/// screenshot and by a colour-blind user, which is why every tone carries its
/// own glyph rather than relying on the hue alone.
///
/// One column rather than the glyph and the text drawn separately into the
/// same place: two widgets centred on the same circle overlap, which is
/// legible only if you know to look for it.
class _Identity extends StatelessWidget {
	const _Identity({
		required this.color,
		required this.icon,
		required this.title,
		required this.subtitle,
	});

	final Color color;
	final IconData icon;
	final String title;
	final String subtitle;

	@override
	Widget build(BuildContext context) {
		final theme = Theme.of(context);
		// Scale-down rather than clip or overflow. The orb is a fixed-size
		// circle, so at a large accessibility text scale this is the only
		// thing that can give — and a label that overflows its own control
		// makes the state unreadable at exactly the moment the user has asked
		// for it to be more readable.
		return FittedBox(
			fit: BoxFit.scaleDown,
			child: Column(
				mainAxisSize: MainAxisSize.min,
				children: [
					Icon(icon, size: 30, color: color),
					const SizedBox(height: VgSpace.md),
					Text(
						title,
						textAlign: TextAlign.center,
						style: theme.textTheme.headlineSmall?.copyWith(
							fontWeight: FontWeight.w700,
							letterSpacing: -0.4,
						),
					),
					const SizedBox(height: VgSpace.xxs),
					Text(
						subtitle,
						textAlign: TextAlign.center,
						maxLines: 2,
						overflow: TextOverflow.ellipsis,
						style: theme.textTheme.bodySmall?.copyWith(color: color),
					),
				],
			),
		);
	}
}