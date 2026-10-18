import 'package:flutter/material.dart';

import 'package:phantrix_core/phantrix_core.dart';

import '../../theme/tokens.dart';
import '../components/surfaces.dart';
import '../shell.dart';

/// Says what the directory currently is: never refreshed, refreshing,
/// current, stale, or broken. A screen that shows an empty list without
/// saying why is indistinguishable from a bug.
class DirectoryBanner extends StatelessWidget {
  const DirectoryBanner({
    required this.snapshot,
    required this.isRefreshing,
    this.onRefresh,
    super.key,
  });

  final DirectorySnapshot snapshot;
  final bool isRefreshing;
  final Future<void> Function()? onRefresh;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final errors = snapshot.providerErrors.values.toList(growable: false);

    if (isRefreshing) {
      return VgBusy(l10n.get('refreshingServers'), compact: true);
    }

    if (errors.isNotEmpty) {
      return _Banner(
        icon: Icons.cloud_off_rounded,
        message: l10n.get('serverListUnavailable'),
        detail: errors.first.message,
        tone: _BannerTone.warning,
        action: onRefresh == null
            ? null
            : TextButton(onPressed: onRefresh, child: Text(l10n.get('retry'))),
      );
    }

    return switch (snapshot.state) {
      DirectoryState.empty => _Banner(
        icon: Icons.refresh_rounded,
        message: l10n.get('noServerListYet'),
        detail: l10n.get('noServerListHint'),
        tone: _BannerTone.neutral,
        action: onRefresh == null
            ? null
            : TextButton(
                onPressed: onRefresh,
                child: Text(l10n.get('refresh')),
              ),
      ),
      DirectoryState.stale => _Banner(
        icon: Icons.schedule_rounded,
        message: l10n.get('serverListStale'),
        tone: _BannerTone.warning,
        action: onRefresh == null
            ? null
            : TextButton(
                onPressed: onRefresh,
                child: Text(l10n.get('refresh')),
              ),
      ),
      DirectoryState.offlineUsingCache => _Banner(
        icon: Icons.cloud_off_rounded,
        message: l10n.get('showingCachedList'),
        tone: _BannerTone.warning,
      ),
      DirectoryState.cacheCorrupt => _Banner(
        icon: Icons.warning_amber_rounded,
        message: l10n.get('cachedListDamaged'),
        tone: _BannerTone.warning,
        action: onRefresh == null
            ? null
            : TextButton(
                onPressed: onRefresh,
                child: Text(l10n.get('refresh')),
              ),
      ),
      DirectoryState.fresh => _Banner(
        icon: Icons.cloud_done_rounded,
        message: l10n.get('serverListCurrent'),
        detail: '${snapshot.serverCount} ${l10n.get('serversAvailable')}',
        tone: _BannerTone.positive,
      ),
    };
  }
}

enum _BannerTone { neutral, positive, warning }

class _Banner extends StatelessWidget {
  const _Banner({
    required this.icon,
    required this.message,
    required this.tone,
    this.detail,
    this.action,
  });

  final IconData icon;
  final String message;
  final String? detail;
  final _BannerTone tone;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = switch (tone) {
      _BannerTone.neutral => theme.colorScheme.onSurfaceVariant,
      _BannerTone.positive => theme.colorScheme.primary,
      _BannerTone.warning => theme.colorScheme.tertiary,
    };
    return Row(
      children: [
        Icon(icon, size: VgIcon.sm, color: color),
        const SizedBox(width: VgSpace.sm),
        // The text is the state; the icon and colour only support it,
        // so nothing here is conveyed by colour alone.
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(message, style: theme.textTheme.bodySmall),
              if (detail != null)
                Text(detail!, style: theme.textTheme.bodySmall),
            ],
          ),
        ),
        ?action,
      ],
    );
  }
}
