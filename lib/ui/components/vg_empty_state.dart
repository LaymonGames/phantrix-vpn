part of 'feedback.dart';

/// An empty state: an explanation of why there is nothing here, and the one
/// action that would fix it.
///
/// Shown instead of a blank list. A list that is simply empty reads as a bug;
/// an empty state that says what is missing and what to do about it reads as
/// the app knowing what it is doing.
class VgEmptyState extends StatelessWidget {
  const VgEmptyState({
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
    this.compact = false,
    super.key,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  /// Drops the oversized icon and the action button.
  ///
  /// For an empty state that appears *inside* a panel that already offers
  /// the same action one screen-reader-height above — two full empty states
  /// on one screen is one too many.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Padding(
          padding: const EdgeInsets.all(VgSpace.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!compact) ...[
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.06),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    icon,
                    size: VgIcon.lg,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: VgSpace.lg),
              ],
              Text(
                title,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleLarge,
              ),
              const SizedBox(height: VgSpace.sm),
              Text(
                message,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
              if (!compact && actionLabel != null && onAction != null) ...[
                const SizedBox(height: VgSpace.xl),
                FilledButton(onPressed: onAction, child: Text(actionLabel!)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
