part of 'feedback.dart';

/// An error with something to do about it.
///
/// Every failure in this app has a next step, because a message that only says
/// something went wrong leaves the user with no action. When there is genuinely
/// no action available, the caller says so in the message rather than showing
/// a button that does nothing.
class VgErrorCard extends StatelessWidget {
  const VgErrorCard({
    required this.message,
    this.code,
    this.actionLabel,
    this.onAction,
    super.key,
  });

  final String message;
  final String? code;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return VgSurface(
      accent: theme.colorScheme.error,
      padding: const EdgeInsets.all(VgSpace.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.error_outline_rounded,
                size: VgIcon.md,
                color: theme.colorScheme.error,
              ),
              const SizedBox(width: VgSpace.md),
              Expanded(
                child: Text(
                  message,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: theme.colorScheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: VgSpace.md),
            Align(
              alignment: Alignment.centerLeft,
              // Wrap the button so a long label wraps instead of
              // overflowing: the button's own text is user-facing
              // copy that changes with the locale.
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 220),
                child: FilledButton.tonal(
                  onPressed: onAction,
                  child: Text(
                    actionLabel!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
          ],
          if (code != null) ...[
            const SizedBox(height: VgSpace.sm),
            Text(
              code!,
              style: theme.textTheme.labelSmall?.copyWith(
                fontFamily: 'monospace',
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
