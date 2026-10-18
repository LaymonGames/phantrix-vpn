import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import 'nav_item.dart';

/// The phone navigation bar.
///
/// Three destinations, always, because three labels survive an accessibility
/// text scale that four or six do not — and the screens that would have been
/// tabs are one tap away from Settings instead.
class VgTabBar extends StatelessWidget {
  const VgTabBar({required this.items, required this.onSelect, super.key});

  final List<VgNavItem> items;
  final void Function(String id) onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border(top: BorderSide(color: scheme.outline)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 64,
          child: Row(
            children: [
              for (final item in items)
                Expanded(
                  child: _TabButton(item: item, onTap: () => onSelect(item.id)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({required this.item, required this.onTap});

  final VgNavItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final selected = item.selected;
    final color = selected ? scheme.primary : scheme.onSurfaceVariant;
    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Stack(
              alignment: Alignment.bottomCenter,
              children: [
                // The indicator is a short bar above the icon
                // rather than a pill behind it: at this height a
                // pill clips the label, and the bar still reads
                // at a glance.
                AnimatedContainer(
                  duration: VgMotion.fast,
                  curve: VgMotion.standard,
                  height: 2,
                  width: selected ? 18 : 0,
                  margin: const EdgeInsets.only(bottom: 6),
                  decoration: BoxDecoration(
                    color: scheme.primary,
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
                Icon(
                  selected ? item.selectedIcon : item.icon,
                  size: VgIcon.md + 2,
                  color: color,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              item.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: color,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
