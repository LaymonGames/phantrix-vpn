part of 'locations_screen.dart';

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.hasServers, required this.filtering});

  /// True when servers exist but the filter excluded them all.
  final bool hasServers;

  final bool filtering;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              filtering ? Icons.search_off_rounded : Icons.public_off_rounded,
              size: 32,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: VgSpace.md),
            Text(
              filtering || hasServers
                  ? l10n.get('noServerInCountry')
                  : l10n.get('noServersFound'),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}
