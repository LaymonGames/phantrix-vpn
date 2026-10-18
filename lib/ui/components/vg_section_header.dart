part of 'containers.dart';

/// A small uppercase heading that separates sections.
class VgSectionHeader extends StatelessWidget {
  const VgSectionHeader(
    this.title, {
    this.trailing,
    this.dense = false,
    super.key,
  });

  final String title;
  final Widget? trailing;

  /// Removes the space above the heading.
  ///
  /// Used inside a panel, where the heading is bounded by the panel rather
  /// than floating between two sections.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      // Generous above and tight below: the space belongs to the heading
      // that introduces the section, not to the section above it.
      padding: EdgeInsets.only(
        bottom: dense ? VgSpace.xs : VgSpace.md,
        top: dense ? 0 : VgSpace.xl,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title.toUpperCase(),
              style: theme.textTheme.labelSmall?.copyWith(
                letterSpacing: 0.9,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          if (trailing != null) ...[trailing!],
        ],
      ),
    );
  }
}
