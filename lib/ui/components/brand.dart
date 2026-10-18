import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import 'status_style.dart';

/// The Phantrix mark.
///
/// This is the shipped app icon, the same drawing as every platform's launcher
/// icon (see tools/generate_app_icons.ps1), so what sits in the dock is what
/// sits in the title bar. The drawn shield below survives only as the
/// errorBuilder fallback: a missing or unreadable asset degrades to a mark
/// that still looks like Phantrix rather than an empty box.
class VgLogo extends StatelessWidget {
  const VgLogo({this.size = 28, super.key});

  final double size;

  @override
  Widget build(BuildContext context) {
    final radius = size * 0.31;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Image.asset(
        'assets/icon.png',
        width: size,
        height: size,
        fit: BoxFit.cover,
        filterQuality: FilterQuality.medium,
        errorBuilder: (context, error, stackTrace) => _DrawnMark(size: size),
      ),
    );
  }
}

/// The hand-drawn stand-in used when the icon asset cannot be loaded.
///
/// A shield with a knocked-out centre, drawn rather than imported so it stays
/// crisp at every size the shell asks for it.
class _DrawnMark extends StatelessWidget {
  const _DrawnMark({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final radius = size * 0.31;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [theme.colorScheme.primary, theme.colorScheme.secondary],
        ),
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Icon(
            Icons.shield_rounded,
            size: size * 0.62,
            color: theme.colorScheme.onPrimary,
          ),
          // A small knocked-out lock inside the shield, in the gradient's
          // own colour, echoing the app icon's padlock.
          Icon(
            Icons.lock_rounded,
            size: size * 0.28,
            color: theme.colorScheme.primary,
          ),
        ],
      ),
    );
  }
}

/// The mark plus the wordmark, for the sidebar header and the welcome screen.
class VgBrand extends StatelessWidget {
  const VgBrand({this.size = 28, this.showName = true, super.key});

  final double size;
  final bool showName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        VgLogo(size: size),
        if (showName) ...[
          const SizedBox(width: VgSpace.sm),
          Text('Phantrix', style: theme.textTheme.titleLarge),
        ],
      ],
    );
  }
}

/// A small coloured dot that carries a connection state.
///
/// Used where there is no room for an icon or a label — a navigation rail, a
/// server row's trailing edge — so it always travels with its label. A bare
/// dot on its own would be colour-only information, which this app never
/// ships.
class VgStatusDot extends StatelessWidget {
  const VgStatusDot({required this.tone, this.size = 8, super.key});

  final VgTone tone;
  final double size;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final accent = VgStatusColors.of(tone, brightness).accent;
    // Idle gets a hollow ring: nothing is happening, and a filled dot
    // would claim otherwise. An active state gets a filled dot with a
    // halo, which is the one place the app uses a glow.
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: tone == VgTone.idle ? Colors.transparent : accent,
        border: tone == VgTone.idle
            ? Border.all(color: accent.withValues(alpha: 0.55), width: 1.5)
            : null,
        boxShadow: tone == VgTone.idle
            ? null
            : [
                BoxShadow(
                  color: accent.withValues(alpha: 0.45),
                  blurRadius: 6,
                  spreadRadius: 1,
                ),
              ],
      ),
    );
  }
}
