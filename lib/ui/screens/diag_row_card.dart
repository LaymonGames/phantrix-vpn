part of 'diagnostics_screen.dart';

class _RowCard extends StatelessWidget {
  const _RowCard({required this.row});

  final DiagRow row;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = VgStatusColors.of(row.status.tone, theme.brightness).accent;
    // A distinct glyph per verdict, so a greyscale screenshot of this
    // screen is still readable and a colour-blind user is not relying on
    // hue alone to tell "protected" from "potential leak".
    final icon = switch (row.status) {
      DiagStatus.passed => Icons.check_circle_outline,
      DiagStatus.warning => Icons.warning_amber_rounded,
      DiagStatus.failed => Icons.dangerous_outlined,
      DiagStatus.notTested => Icons.help_outline_rounded,
      DiagStatus.notSupported => Icons.block_rounded,
    };
    return VgSurface(
      padding: const EdgeInsets.all(VgSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: VgIcon.sm, color: color),
              const SizedBox(width: VgSpace.sm),
              Expanded(
                child: Text(row.title, style: theme.textTheme.titleSmall),
              ),
              const SizedBox(width: VgSpace.sm),
              Text(
                row.status.label(L10n.of(context)),
                style: theme.textTheme.labelMedium?.copyWith(color: color),
              ),
            ],
          ),
          if (row.value != null) ...[
            const SizedBox(height: VgSpace.sm),
            Text(row.value!, style: theme.textTheme.bodyMedium),
          ],
          if (row.detail != null) ...[
            const SizedBox(height: VgSpace.xs),
            Text(row.detail!, style: theme.textTheme.bodySmall),
          ],
        ],
      ),
    );
  }
}
