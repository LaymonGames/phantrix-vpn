import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import 'brand.dart';
import 'nav_item.dart';

/// The desktop navigation rail.
///
/// A real sidebar rather than a Material [NavigationRail]: the shell needs a
/// header with the wordmark and a footer with the live connection state, and
/// both need to sit *outside* the item list. A sidebar that reports whether
/// the tunnel is up, from every screen, is the whole point of having space
/// for one.
class VgSidebar extends StatelessWidget {
  const VgSidebar({
    required this.items,
    required this.onSelect,
    this.status,
    this.width = 248,
    super.key,
  });

  final List<VgNavItem> items;
  final void Function(String id) onSelect;

  /// The live connection summary in the footer.
  final Widget? status;

  final double width;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      width: width,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        // A single hairline rather than a shadow: the sidebar is flush
        // with the content beside it, and a border is what separates
        // two planes that touch.
        border: BorderDirectional(
          end: BorderSide(color: theme.colorScheme.outline),
        ),
        boxShadow: isDark ? null : VgShadow.forSidebar(Colors.black),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(
              VgSpace.lg,
              VgSpace.xl,
              VgSpace.lg,
              VgSpace.lg,
            ),
            child: VgBrand(size: 30),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: VgSpace.md),
            child: Divider(color: theme.colorScheme.outline, height: 1),
          ),
          const SizedBox(height: VgSpace.md),
          for (final item in items)
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: VgSpace.md,
                vertical: 2,
              ),
              child: _SidebarRow(item: item, onTap: () => onSelect(item.id)),
            ),
          const Spacer(),
          if (status != null)
            Padding(padding: const EdgeInsets.all(VgSpace.md), child: status),
        ],
      ),
    );
  }
}

class _SidebarRow extends StatefulWidget {
  const _SidebarRow({required this.item, required this.onTap});

  final VgNavItem item;
  final VoidCallback onTap;

  @override
  State<_SidebarRow> createState() => _SidebarRowState();
}

class _SidebarRowState extends State<_SidebarRow> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final item = widget.item;
    final selected = item.selected;

    // A real focusable control rather than a bare gesture detector, so the
    // sidebar can be walked with Tab and activated with Enter or Space on
    // Windows, and the focused row shows a visible ring.
    return Semantics(
      button: true,
      selected: selected,
      label: item.label,
      excludeSemantics: true,
      child: Tooltip(
        message: item.label,
        waitDuration: const Duration(milliseconds: 600),
        child: FocusableActionDetector(
          mouseCursor: SystemMouseCursors.click,
          onShowHoverHighlight: (v) => setState(() => _hovered = v),
          onShowFocusHighlight: (v) => setState(() => _focused = v),
          actions: <Type, Action<Intent>>{
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                widget.onTap();
                return null;
              },
            ),
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: VgMotion.fast,
              curve: VgMotion.standard,
              padding: EdgeInsetsDirectional.fromSTEB(
                item.indented ? VgSpace.xl : VgSpace.sm,
                VgSpace.sm + 3,
                VgSpace.md,
                VgSpace.sm + 3,
              ),
              decoration: BoxDecoration(
                color: selected
                    ? scheme.primary.withValues(alpha: 0.12)
                    : _hovered
                    ? scheme.onSurface.withValues(alpha: 0.05)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(VgRadius.md),
                border: Border.all(
                  color: _focused ? scheme.primary : Colors.transparent,
                  width: 2,
                ),
              ),
              child: Row(
                children: [
                  // The selection marker: a short bar on the leading
                  // edge, so the current section reads by shape as well
                  // as by tint.
                  AnimatedContainer(
                    duration: VgMotion.fast,
                    curve: VgMotion.standard,
                    width: 3,
                    height: selected ? 18 : 0,
                    margin: const EdgeInsetsDirectional.only(end: VgSpace.sm),
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      borderRadius: BorderRadius.circular(VgRadius.pill),
                    ),
                  ),
                  if (item.indented) ...[
                    const Icon(
                      Icons.subdirectory_arrow_right_rounded,
                      size: VgIcon.sm,
                      color: VgColors.inkFaint,
                    ),
                    const SizedBox(width: VgSpace.xs),
                  ],
                  Icon(
                    selected ? item.selectedIcon : item.icon,
                    size: VgIcon.md,
                    color: selected ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: VgSpace.md),
                  Expanded(
                    child: Text(
                      item.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: selected
                            ? scheme.onSurface
                            : scheme.onSurfaceVariant,
                        fontWeight: selected
                            ? FontWeight.w700
                            : FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
