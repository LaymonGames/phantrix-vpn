part of 'feedback.dart';

/// A shimmerless busy indicator with a label.
///
/// A bare spinner tells the user something is happening and nothing else.
/// Naming the operation is the difference between "the app is thinking" and
/// "the app is talking to the server directory", and it costs one line.
class VgBusy extends StatelessWidget {
  const VgBusy(this.message, {this.compact = false, super.key});

  final String message;

  /// A spinner and the label on one line, for a button or a panel header.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (compact) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: VgIcon.sm,
            height: VgIcon.sm,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: VgSpace.sm),
          Text(message, style: theme.textTheme.labelMedium),
        ],
      );
    }
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 26,
            height: 26,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
          const SizedBox(height: VgSpace.md),
          Text(message, style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }
}
