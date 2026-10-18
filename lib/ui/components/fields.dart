import 'package:flutter/material.dart';

import '../../theme/tokens.dart';

/// A labelled value, the workhorse of every details panel.
///
/// The value wraps and the label does not, and both flex, because a fixed-width
/// column of labels overflows the moment the user enlarges the text — which is
/// exactly what an accessibility setting is for.
class VgInfoRow extends StatelessWidget {
  const VgInfoRow({
    required this.label,
    required this.value,
    this.icon,
    this.valueStyle,
    this.monospace = false,
    super.key,
  });

  final String label;
  final String value;
  final IconData? icon;
  final TextStyle? valueStyle;

  /// Renders the value in a fixed-pitch face, which is right for an address
  /// or a key and wrong for a sentence.
  final bool monospace;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: VgSpace.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null) ...[
            Icon(
              icon,
              size: VgIcon.sm,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: VgSpace.md),
          ],
          Expanded(flex: 4, child: Text(label, style: muted)),
          const SizedBox(width: VgSpace.md),
          Expanded(
            flex: 5,
            child: Text(
              value,
              textAlign: TextAlign.end,
              style:
                  valueStyle ??
                  theme.textTheme.titleMedium?.copyWith(
                    fontFamily: monospace ? 'monospace' : null,
                    fontFeatures: monospace ? null : VgType.tabular,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A compact metric.
///
/// Used in a row of three or four, never alone: a single number floating on its
/// own reads as important, and these numbers are not.
class VgStat extends StatelessWidget {
  const VgStat({
    required this.label,
    required this.value,
    this.icon,
    this.tone,
    super.key,
  });

  final String label;
  final String value;
  final IconData? icon;

  /// Overrides the default emphasis. Used to make a live figure stand out.
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: VgSpace.md,
        vertical: VgSpace.md,
      ),
      decoration: BoxDecoration(
        // Inset a step below the panel it sits in, so a group of three
        // reads as one object with three figures rather than three
        // cards competing with the card around them.
        color: theme.colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(VgRadius.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                Icon(
                  icon,
                  size: VgIcon.sm - 3,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: VgSpace.xs),
              ],
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: VgSpace.xs),
          FittedBox(
            // The number must never wrap onto a second line: a stat
            // that is two lines tall breaks the row it sits in.
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              maxLines: 1,
              style: theme.textTheme.titleMedium?.copyWith(
                color: tone ?? theme.colorScheme.onSurface,
                fontFeatures: VgType.tabular,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A short, coloured state chip.
///
/// Distinct from a badge that reports a count: this one carries *meaning*, so
/// it always has a label and never a bare number without context.
class VgChip extends StatelessWidget {
  const VgChip({
    required this.label,
    required this.color,
    this.icon,
    this.filled = true,
    super.key,
  });

  final String label;
  final Color color;
  final IconData? icon;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: filled ? 0.14 : 0.0),
        borderRadius: BorderRadius.circular(VgRadius.pill),
        border: Border.all(color: color.withValues(alpha: filled ? 0.0 : 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 6),
          ],
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}
