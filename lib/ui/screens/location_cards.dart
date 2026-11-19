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

class CountryCard extends StatefulWidget {
  const CountryCard({
    required this.entry,
    required this.selected,
    required this.onSelected,
    this.selectedRegion,
    this.onRegionSelected,
    super.key,
  });

  final CountryEntry entry;
  final bool selected;
  final void Function(String countryCode) onSelected;

  /// The chosen state when this country is selected; null means fastest.
  final String? selectedRegion;

  /// Called with this country and a state; a null state means "fastest".
  final void Function(String countryCode, String? region)? onRegionSelected;

  @override
  State<CountryCard> createState() => _CountryCardState();
}

class _CountryCardState extends State<CountryCard> {
  late bool _expanded = widget.selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final entry = widget.entry;
    final selected = widget.selected;
    final states = entry.states;
    // Every country expands, so "Fastest" is always offered; states appear
    // under it once their lookup has resolved.
    // A dash, not a number: latency that was never measured is unknown.
    final latency = entry.bestLatencyMs;
    final latencyText = latency == null ? '—' : '$latency ms';
    final region = widget.selectedRegion;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);

    void pick(String? state) {
      final callback = widget.onRegionSelected;
      if (callback != null) {
        callback(entry.code, state);
      } else {
        widget.onSelected(entry.code);
      }
    }

    return VgSurface(
      accent: selected ? theme.colorScheme.primary : null,
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
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
                  const SizedBox(width: VgSpace.xs),
                  AnimatedRotation(
                    turns: _expanded ? 0.5 : 0,
                    duration: reduceMotion ? Duration.zero : VgMotion.fast,
                    curve: VgMotion.standard,
                    child: Icon(
                      Icons.expand_more_rounded,
                      color: _expanded
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurfaceVariant,
                      size: VgIcon.md,
                    ),
                  ),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: reduceMotion ? Duration.zero : VgMotion.fast,
            curve: VgMotion.standard,
            alignment: Alignment.topCenter,
            child: !_expanded
                ? const SizedBox(width: double.infinity)
                : Padding(
                    padding: const EdgeInsetsDirectional.fromSTEB(
                      VgSpace.md,
                      0,
                      VgSpace.md,
                      VgSpace.md,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Divider(
                          height: 1,
                          color: theme.colorScheme.outlineVariant.withValues(
                            alpha: 0.5,
                          ),
                        ),
                        const SizedBox(height: VgSpace.sm),
                        _StateRow(
                          icon: Icons.bolt_rounded,
                          label: l10n.get('fastest'),
                          caption: null,
                          latencyMs: latency,
                          highlight: true,
                          selected: selected && region == null,
                          onTap: () => pick(null),
                        ),
                        for (final state in states) ...[
                          const SizedBox(height: VgSpace.xxs),
                          _StateRow(
                            icon: Icons.location_on_rounded,
                            label: state.name,
                            caption:
                                '${state.serverCount} '
                                '${l10n.get('serversAvailable')}',
                            latencyMs: state.bestLatencyMs,
                            selected: selected && region == state.name,
                            onTap: () => pick(state.name),
                          ),
                        ],
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// One selectable state (or "Fastest") under an expanded country.
///
/// A rounded tile rather than a bare row, so the choices read as a set of
/// options inside the country card; the selected one is filled with the
/// accent tint and carries a check, matching how the card marks selection.
class _StateRow extends StatelessWidget {
  const _StateRow({
    required this.icon,
    required this.label,
    required this.caption,
    required this.latencyMs,
    required this.selected,
    required this.onTap,
    this.highlight = false,
  });

  final IconData icon;
  final String label;
  final String? caption;
  final int? latencyMs;
  final bool selected;
  final bool highlight;
  final VoidCallback onTap;

  /// Green under 80 ms, amber under 200 ms, red beyond; grey when unmeasured.
  Color _latencyColor(ColorScheme scheme) {
    final ms = latencyMs;
    if (ms == null) {
      return scheme.onSurfaceVariant;
    }
    if (ms < 80) {
      return const Color(0xFF2E9E5B);
    }
    if (ms < 200) {
      return const Color(0xFFD08A1E);
    }
    return scheme.error;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final accent = selected
        ? scheme.primary
        : highlight
        ? scheme.tertiary
        : scheme.onSurfaceVariant;
    final latencyColor = _latencyColor(scheme);
    return Material(
      color: selected
          ? scheme.primary.withValues(alpha: 0.10)
          : scheme.onSurface.withValues(alpha: 0.03),
      borderRadius: BorderRadius.circular(VgRadius.sm),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(VgRadius.sm),
            border: Border.all(
              color: selected
                  ? scheme.primary.withValues(alpha: 0.45)
                  : Colors.transparent,
            ),
          ),
          padding: const EdgeInsets.all(VgSpace.sm),
          child: Row(
            children: [
              // The leading circle is the selection indicator: a ring with
              // the row's icon when idle, filled with a check when chosen.
              AnimatedContainer(
                duration: VgMotion.fast,
                width: 30,
                height: 30,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: selected
                      ? scheme.primary
                      : accent.withValues(alpha: 0.08),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: selected
                        ? scheme.primary
                        : accent.withValues(alpha: 0.5),
                    width: 1.5,
                  ),
                ),
                child: Icon(
                  selected ? Icons.check_rounded : icon,
                  size: VgIcon.sm,
                  color: selected ? scheme.onPrimary : accent,
                ),
              ),
              const SizedBox(width: VgSpace.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: selected ? scheme.primary : null,
                        fontWeight: selected || highlight
                            ? FontWeight.w600
                            : FontWeight.w500,
                      ),
                    ),
                    if (caption != null)
                      Text(
                        caption!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: VgSpace.sm),
              // Latency as a small pill with a signal dot, so a column of
              // states can be scanned for the quick ones at a glance.
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: VgSpace.sm,
                  vertical: VgSpace.xxs,
                ),
                decoration: BoxDecoration(
                  color: latencyColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(VgRadius.pill),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: latencyColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: VgSpace.xs),
                    Text(
                      latencyMs == null ? '—' : '$latencyMs ms',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: latencyColor,
                        fontWeight: FontWeight.w600,
                        fontFeatures: VgType.tabular,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
