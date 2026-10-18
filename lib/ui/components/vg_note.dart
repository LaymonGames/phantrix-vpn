part of 'feedback.dart';

/// An explanatory note.
///
/// Used for the things a user needs told — a platform limitation, a repair
/// that will be applied, a caution about what a public relay can see. Its tone
/// is neutral by default because a note is usually information rather than a
/// problem, and colouring everything as a warning trains people to ignore
/// colour.
class VgNote extends StatelessWidget {
  const VgNote({
    required this.message,
    this.icon = Icons.info_outline_rounded,
    this.color,
    this.title,
    this.action,
    super.key,
  });

  final String message;
  final IconData icon;
  final Color? color;
  final String? title;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tone = color ?? theme.colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.all(VgSpace.md),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(VgRadius.md),
        // A single hairline in the same hue at low alpha. The tint
        // alone is too soft to find with a glance on a busy screen,
        // and a full-strength border would shout.
        border: Border.all(color: tone.withValues(alpha: 0.22)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: VgIcon.sm, color: tone),
          const SizedBox(width: VgSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (title != null) ...[
                  Text(title!, style: theme.textTheme.titleSmall),
                  const SizedBox(height: 2),
                ],
                Text(message, style: theme.textTheme.bodySmall),
                if (action != null) ...[
                  const SizedBox(height: VgSpace.sm),
                  action!,
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
