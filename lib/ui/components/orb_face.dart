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
