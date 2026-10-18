part of 'rows.dart';

/// One option in a closed set: a button that looks pressed while it is the
/// current choice.
///
/// Public because the servers screen's sort filters are exactly this control,
/// and giving them their own Material chip means a second selected-state
/// palette in the app — which is how a screen ends up with white text on a
/// pale fill, readable in neither theme.
class VgSegment extends StatelessWidget {
  const VgSegment({
    required this.label,
    required this.selected,
    required this.onTap,
    this.selectedIcon = Icons.check_rounded,
    super.key,
  });

  final String label;
  final bool selected;

  /// The action that selects this option, or null when the platform cannot
  /// apply the setting it belongs to.
  final VoidCallback? onTap;

  /// Shown instead of the checkmark when this segment is selected. For a
  /// setting, the tick says "this is the value". A sort filter has no value
  /// to assert, so it passes null and is marked by its fill alone.
  final IconData? selectedIcon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final interactive = onTap != null;
    // The selected segment carries its own explicit colours. An ambient
    // chip theme paints every label in muted ink, which on a selected
    // segment's tint is roughly a 3:1 ratio — unreadable at exactly the
    // moment the user most needs to read it. `primary` reads on both the
    // dark and the light tint.
    //
    // A segment the platform cannot honour drops the selection tint with
    // the tap: nothing about it is a live choice, so nothing about it should
    // look chosen.
    final chosen = selected && interactive;
    final foreground = !interactive
        ? scheme.onSurfaceVariant.withValues(alpha: 0.6)
        : chosen
        ? scheme.primary
        : scheme.onSurfaceVariant;
    return Semantics(
      button: interactive,
      enabled: interactive,
      selected: chosen,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(VgRadius.sm),
        child: AnimatedContainer(
          duration: VgMotion.fast,
          curve: VgMotion.standard,
          // No `alignment` here: an aligned container expands to fill
          // whatever width it is offered, which turns every option
          // into a full-width bar and makes a three-option setting
          // look like a stacked form.
          padding: const EdgeInsets.symmetric(
            horizontal: VgSpace.md,
            vertical: VgSpace.sm,
          ),
          decoration: BoxDecoration(
            color: chosen
                ? scheme.primary.withValues(alpha: 0.14)
                : scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(VgRadius.sm),
            border: Border.all(
              color: chosen
                  ? scheme.primary
                  : interactive
                  ? scheme.outline
                  : scheme.outline.withValues(alpha: 0.4),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (chosen && selectedIcon != null) ...[
                Icon(selectedIcon!, size: VgIcon.sm, color: foreground),
                const SizedBox(width: 6),
              ],
              // Flexible, so a long option label wraps onto a second
              // line inside its own segment rather than overflowing it.
              // A settings option that is truncated is a setting the
              // user cannot read the value of — and on a phone the
              // longest of these ("VPN server DNS") is wider than the
              // space a segment gets.
              Flexible(
                child: Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: foreground,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
