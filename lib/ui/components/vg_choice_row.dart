part of 'rows.dart';

/// A settings row offering a closed set of mutually exclusive options.
///
/// Segments rather than a dropdown and rather than a row of chips: the options
/// for every setting in this app are two or three short words, so showing them
/// all at once turns a two-tap decision into one, and removes the dialog that
/// used to sit between the user and a setting they came to change.
///
/// A [Wrap], never a [Row], so a long label or a large accessibility text scale
/// pushes the last segment onto a second line instead of clipping it. That is
/// the same reason the old quick-action row was a wrap.
class VgChoiceRow extends StatelessWidget {
  const VgChoiceRow({
    required this.title,
    required this.value,
    required this.options,
    this.note,
    this.icon,
    this.enabled = true,
    super.key,
  });

  final String title;
  final String value;

  /// Label to the action that selects it. Insertion-ordered, because the
  /// order the caller wrote is the order a reader expects.
  final Map<String, VoidCallback> options;

  /// Shown beneath the segments — an explanation, or the reason the platform
  /// cannot honour this setting.
  final String? note;

  final IconData? icon;

  /// Whether this platform can honour the setting at all.
  ///
  /// A choice that cannot be applied is shown with its segments muted and
  /// unresponsive rather than hidden: the row still says the setting exists
  /// and why it does nothing, where a tap that silently changed a stored
  /// value nothing reads would say the opposite.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: VgSpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: VgIcon.sm, color: scheme.onSurfaceVariant),
                const SizedBox(width: VgSpace.sm),
              ],
              Expanded(child: Text(title, style: theme.textTheme.bodyLarge)),
            ],
          ),
          const SizedBox(height: VgSpace.sm),
          Wrap(
            spacing: VgSpace.sm,
            runSpacing: VgSpace.sm,
            children: [
              for (final entry in options.entries)
                VgSegment(
                  label: entry.key,
                  selected: entry.key == value,
                  onTap: enabled ? entry.value : null,
                ),
            ],
          ),
          if (note != null) ...[
            const SizedBox(height: VgSpace.sm),
            Text(note!, style: theme.textTheme.bodySmall),
          ],
        ],
      ),
    );
  }
}
