import 'dart:math' as math;

import 'package:flutter/material.dart';

class OrbBloom extends StatelessWidget {
  const OrbBloom({
    required this.color,
    required this.strength,
    required this.size,
    super.key,
  });

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

class OrbTrack extends StatelessWidget {
  const OrbTrack({required this.color, required this.size, super.key});

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
class OrbRing extends StatelessWidget {
  const OrbRing({
    required this.color,
    required this.progress,
    required this.pulsing,
    required this.complete,
    required this.size,
    required this.animation,
    super.key,
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
            painter: OrbRingPainter(
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

class OrbRingPainter extends CustomPainter {
  OrbRingPainter({
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
    canvas.drawArc(
      rect2,
      _startAngle + _gap,
      2 * math.pi - _gap * 2,
      false,
      paint,
    );
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
  bool shouldRepaint(covariant OrbRingPainter old) =>
      old.progress != progress ||
      old.complete != complete ||
      old.sweep != sweep ||
      old.color != color ||
      // Only re-compare the phase when something is actually animating;
      // otherwise a static ring would request a repaint on every frame.
      (sweep != null && old.phase != phase);
}
