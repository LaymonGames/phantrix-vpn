part of 'rows.dart';

/// A tappable row with an icon, a title, an optional subtitle and a trailing
/// control — the shape almost every navigable thing in the app takes.
///
/// Built on Material's [ListTile] rather than on a `Row` of boxes. That is
/// deliberate: a hand-rolled row has to reimplement the ripple, the focus
/// order, the semantic role and the keyboard activation, and a screen test
/// that has to search for a `ListTile` to tap a server row is a test that
/// documents the right abstraction. The app styles the tile; it does not
/// reinvent it.
class VgListRow extends StatelessWidget {
  const VgListRow({
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
    this.selected = false,
    this.showDivider = false,
    this.contentPadding = const EdgeInsets.symmetric(vertical: VgSpace.xs),
    super.key,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool selected;
  final bool showDivider;

  /// How the tile's own content is inset.
  ///
  /// No horizontal inset by default, because these rows live inside a panel
  /// that already supplies one. A row that adds a second 16px puts its text
  /// out of line with the heading above it, which is the sort of drift that
  /// makes a settings screen look assembled rather than designed. Callers
  /// placing a row directly on the background pass their own.
  final EdgeInsetsGeometry contentPadding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // A transparent `Material` above the surface's own decoration.
    // [ListTile] paints its selection tint and its ink splash on the
    // nearest `Material` ancestor; without one it reaches past this surface
    // to whatever is behind it, and the selection and the splash both
    // disappear under the card's fill. Transparency keeps the card's
    // background and its shadow, and hands the tile the surface it was
    // already painting on.
    return Material(
      type: MaterialType.transparency,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            onTap: onTap,
            selected: selected,
            selectedTileColor: theme.colorScheme.primary.withValues(
              alpha: 0.07,
            ),
            // A hairline under the row rather than a gap: a settings
            // list read as a stack of separate cards loses the sense
            // that it is one list.
            contentPadding: contentPadding,
            minTileHeight: 56,
            leading: leading,
            title: Text(title),
            subtitle: subtitle == null ? null : Text(subtitle!),
            trailing:
                trailing ??
                (onTap == null
                    ? null
                    : const Icon(Icons.chevron_right_rounded)),
          ),
          if (showDivider)
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 56),
              child: Divider(color: theme.colorScheme.outline, height: 1),
            ),
        ],
      ),
    );
  }
}
