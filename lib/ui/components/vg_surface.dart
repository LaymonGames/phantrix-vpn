part of 'containers.dart';

/// A raised surface.
///
/// The single card primitive in the app. Screens compose from this rather than
/// using [Card] directly so that the elevation, radius and padding stay
/// identical everywhere — which is what makes a screen feel designed rather
/// than assembled.
class VgSurface extends StatelessWidget {
  const VgSurface({
    required this.child,
    this.padding = const EdgeInsets.all(VgSpace.lg),
    this.onTap,
    this.accent,
    this.elevated = false,
    this.outlined = false,
    this.clip = true,
    super.key,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  /// When set, the surface becomes a button.
  final VoidCallback? onTap;

  /// A hairline in this colour along the leading edge, used to mark the
  /// selected item in a list.
  final Color? accent;

  final bool elevated;

  /// Draws a hairline around the surface.
  ///
  /// Off by default, because depth comes from layered surfaces rather than
  /// outlines. It is on for surfaces that sit *inside* another surface —
  /// an inset well — where there is no tonal step to separate them.
  final bool outlined;

  /// Whether to clip the children to [radius].
  ///
  /// Off for a surface whose child paints its own edge decoration, such as
  /// an accent bar that must not be rounded away.
  final bool clip;

  static BorderRadius radiusFor(double r) => BorderRadius.circular(r);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final radius = BorderRadius.circular(VgRadius.lg);

    final content = Padding(padding: padding, child: child);

    Widget surface = DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: radius,
        border: outlined
            ? Border.all(color: theme.colorScheme.outlineVariant)
            : null,
        boxShadow: elevated
            ? VgShadow.forCard(isDark ? Colors.black : const Color(0xFF1E3A2B))
            : null,
      ),
      child: content,
    );

    // The accent is a separate inset rather than a one-sided `Border`:
    // a `Border` with different colours per side has no valid borderRadius,
    // and Flutter refuses to paint one. Clipping to the radius and drawing
    // the strip inside gives the same result and is legal.
    if (accent != null) {
      surface = ClipRRect(
        borderRadius: radius,
        child: Stack(
          children: [
            surface,
            PositionedDirectional(
              start: 0,
              top: 0,
              bottom: 0,
              width: 3,
              child: ColoredBox(color: accent!),
            ),
          ],
        ),
      );
    }

    if (onTap == null) {
      return surface;
    }
    return _Pressable(onTap: onTap!, borderRadius: radius, child: surface);
  }
}

/// Adds a press-scale to a tappable surface.
///
/// The scale is small — 1.5% — because a large one makes a list of servers feel
/// like a toy, and because a surface that shrinks visibly reflows the text
/// inside it.
class _Pressable extends StatefulWidget {
  const _Pressable({
    required this.child,
    required this.onTap,
    required this.borderRadius,
  });

  final Widget child;
  final VoidCallback onTap;
  final BorderRadius borderRadius;

  @override
  State<_Pressable> createState() => _PressableState();
}

class _PressableState extends State<_Pressable> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          onTap: widget.onTap,
          child: AnimatedScale(
            scale: _pressed ? 0.985 : 1,
            duration: VgMotion.fast,
            curve: VgMotion.standard,
            child: DecoratedBox(
              decoration: ShapeDecoration(
                color: _pressed
                    ? theme.colorScheme.onSurface.withValues(alpha: 0.04)
                    : const Color(0x00000000),
                shape: RoundedRectangleBorder(
                  borderRadius: widget.borderRadius,
                ),
              ),
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}
