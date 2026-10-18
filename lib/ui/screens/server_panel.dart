part of 'home_details.dart';

class ServerPanel extends StatelessWidget {
  const ServerPanel({
    required this.view,
    required this.selectedCountryCode,
    required this.onChooseLocation,
    super.key,
  });

  final ConnectionView view;
  final String selectedCountryCode;
  final VoidCallback onChooseLocation;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);
    final rawLabel = view.selectedLabel;
    final selectedLabel = selectedCountryCode == 'AUTO'
        ? l10n.get('automaticLocation')
        : GeoDatabase.nameOf(selectedCountryCode, l10n.languageCode);
    // Prefer the active tunnel's destination while it is connecting or
    // connected. Otherwise show the saved preference, including after a
    // failed attempt; a previous session's server must not override the
    // location the user just selected.
    final label = (view.isConnected || view.isBusy) && rawLabel != null
        ? ((GeoDatabase.byIso2(rawLabel) != null ||
                  GeoDatabase.byIso3(rawLabel) != null)
              ? GeoDatabase.nameOf(rawLabel, l10n.languageCode)
              : rawLabel)
        : selectedLabel;
    return VgSurface(
      onTap: onChooseLocation,
      padding: EdgeInsets.zero,
      child: Row(
        children: [
          const SizedBox(width: VgSpace.md),
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(VgRadius.sm),
            ),
            child: Icon(
              view.selectedLabel == null
                  ? Icons.public_rounded
                  : Icons.dns_rounded,
              size: VgIcon.md,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(width: VgSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 2),
                Text(
                  view.selectedLabel == null
                      ? l10n.get('savedLocationHint')
                      : l10n.get('tapToChangeLocation'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right_rounded, size: VgIcon.md),
          const SizedBox(width: VgSpace.sm),
        ],
      ),
    );
  }
}
