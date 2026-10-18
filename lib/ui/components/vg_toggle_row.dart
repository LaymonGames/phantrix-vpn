part of 'rows.dart';

/// A settings row that switches.
///
/// The reason a control is disabled, when there is one, is rendered underneath
/// the row rather than in a tooltip: a control the platform cannot honour must
/// say so on the screen, not on hover.
class VgToggleRow extends StatelessWidget {
  const VgToggleRow({
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.enabled = true,
    this.disabledReason,
    super.key,
  });

  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool enabled;
  final String? disabledReason;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: VgSpace.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: enabled
                            ? theme.colorScheme.onSurface
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(subtitle!, style: theme.textTheme.bodySmall),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: VgSpace.lg),
              Switch(value: value, onChanged: enabled ? onChanged : null),
            ],
          ),
          if (!enabled && disabledReason != null)
            Padding(
              padding: const EdgeInsets.only(top: VgSpace.xs),
              child: Text(disabledReason!, style: theme.textTheme.bodySmall),
            ),
        ],
      ),
    );
  }
}
