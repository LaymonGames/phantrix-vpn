import 'package:flutter/material.dart';

import 'package:phantrix_core/phantrix_core.dart';

import '../../theme/tokens.dart';
import '../components/rows.dart';
import '../components/surfaces.dart';
import '../shell.dart';
import 'country_directory.dart';

class AutoLocationCard extends StatelessWidget {
  const AutoLocationCard({
    required this.selected,
    required this.label,
    required this.detail,
    required this.onSelected,
    super.key,
  });

  final bool selected;
  final String label;
  final String detail;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return VgSurface(
      onTap: onSelected,
      // The accent bar rather than a tinted fill: automatic is the
      // default, and it should be marked the way the app marks every
      // other selection, not as a warning.
      accent: selected ? theme.colorScheme.primary : null,
      padding: EdgeInsets.zero,
      child: VgListRow(
        contentPadding: const EdgeInsets.symmetric(
          horizontal: VgSpace.md,
          vertical: VgSpace.sm,
        ),
        leading: LeadingBadge(
          icon: Icons.auto_awesome_rounded,
          selected: selected,
        ),
        title: label,
        subtitle: detail,
        trailing: Icon(
          selected ? Icons.check_circle_rounded : Icons.chevron_right_rounded,
          color: selected
              ? theme.colorScheme.primary
              : theme.colorScheme.onSurfaceVariant,
          size: VgIcon.md,
        ),
      ),
    );
  }
}

/// The icon well at the head of a row.
///
/// Shared by the automatic card and the country rows so a selected row and an
/// unselected one differ in exactly one way — the colour of this badge — and
/// nothing else on the row has to be restyled to keep them matched.
class LeadingBadge extends StatelessWidget {
  const LeadingBadge({
    required this.icon,
    required this.selected,
    this.text,
    super.key,
  });

  final IconData icon;
  final bool selected;
  final String? text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = selected
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;
    return Container(
      width: 38,
      height: 38,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(VgRadius.sm),
      ),
      child: text == null
          ? Icon(icon, size: VgIcon.md, color: color)
          : Text(text!, style: const TextStyle(fontSize: 20)),
    );
  }
}

class CountryCard extends StatelessWidget {
  const CountryCard({
    required this.entry,
    required this.selected,
    required this.onSelected,
    super.key,
  });

  final CountryEntry entry;
  final bool selected;
  final void Function(String countryCode) onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    // A dash, not a number: latency that was never measured is unknown.
    final latency = entry.bestLatencyMs;
    final latencyText = latency == null ? '—' : '$latency ms';

    return VgSurface(
      onTap: () => onSelected(entry.code),
      accent: selected ? theme.colorScheme.primary : null,
      padding: EdgeInsets.zero,
      child: VgListRow(
        contentPadding: const EdgeInsets.symmetric(
          horizontal: VgSpace.md,
          vertical: VgSpace.sm,
        ),
        leading: LeadingBadge(
          icon: Icons.dns_rounded,
          selected: selected,
          text: entry.flag,
        ),
        title: l10n.isRtl ? entry.nameFor('ar') : entry.nameFor('en'),
        subtitle:
            '${entry.serverCount} ${l10n.get('serversAvailable')} · '
            '${entry.protocols.map((p) => p.shortLabel).join(', ')}',
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (entry.trust == TrustLevel.publicRelay)
              Tooltip(
                message: l10n.get('publicRelayWarning'),
                child: Icon(
                  Icons.gpp_maybe_outlined,
                  size: VgIcon.sm,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            const SizedBox(width: VgSpace.sm),
            // The one figure in the row that decides an ordering,
            // given tabular figures so the column of them lines up
            // down the list instead of shimmering.
            Text(
              latencyText,
              style: theme.textTheme.labelMedium?.copyWith(
                fontFeatures: VgType.tabular,
              ),
            ),
            if (selected) ...[
              const SizedBox(width: VgSpace.sm),
              Icon(
                Icons.check_circle_rounded,
                color: theme.colorScheme.primary,
                size: VgIcon.md,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
