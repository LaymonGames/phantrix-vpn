import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import 'status_style.dart';

class OrbFace extends StatelessWidget {
  const OrbFace({
    required this.color,
    required this.edge,
    required this.state,
    required this.size,
    super.key,
  });

  final Color color;
  final Color edge;
  final VgTone state;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final idle = state == VgTone.idle;
    // Lit from above: a radial highlight toward the top makes the face read
    // as a physical button without a heavy drop shadow under it.
    final top = Color.lerp(color, Colors.white, isDark ? 0.10 : 0.70)!;
    final bottom = isDark
        ? Color.lerp(color, Colors.black, 0.18)!
        : Color.lerp(color, Colors.white, 0.15)!;
    return AnimatedContainer(
      duration: VgMotion.normal,
      curve: VgMotion.emphasised,
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          center: const Alignment(0, -0.55),
          radius: 1.05,
          colors: [top, bottom],
        ),
        border: Border.all(
          color: idle
              ? theme.colorScheme.outlineVariant.withValues(alpha: 0.9)
              : edge.withValues(alpha: 0.45),
          width: 1.5,
        ),
        boxShadow: [
          // A glow in the state's own colour rather than a grey shadow:
          // the orb is a light source, not a card.
          BoxShadow(
            color: (idle ? Colors.black : edge).withValues(
              alpha: idle ? (isDark ? 0.35 : 0.08) : (isDark ? 0.30 : 0.22),
            ),
            blurRadius: idle ? 28 : 46,
            spreadRadius: idle ? -4 : -2,
            offset: Offset(0, idle ? 4 : 0),
          ),
        ],
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
class OrbIdentity extends StatelessWidget {
  const OrbIdentity({
    required this.color,
    required this.icon,
    required this.title,
    required this.subtitle,
    super.key,
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
