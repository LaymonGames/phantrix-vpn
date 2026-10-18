part of 'app_theme.dart';

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
