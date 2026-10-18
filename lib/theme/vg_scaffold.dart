part of 'app_theme.dart';

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
