import 'dart:async';

import 'package:flutter/material.dart';

import 'package:phantrix_core/phantrix_core.dart';
import 'package:phantrix_platform/phantrix_platform.dart';

import '../../../settings/settings_controller.dart';
import '../../../theme/tokens.dart';
import '../../components/rows.dart';
import '../../components/surfaces.dart';
import '../../shell.dart';

/// Applies a split-tunnel policy to a running tunnel.
///
/// Answers null when there is no running tunnel to apply it to, which is not
/// a failure: the stored preference is used on the next connection.
typedef SplitTunnelLiveApply = Future<Result<void>?> Function(
  SplitTunnelSettings policy,
);

/// The Split tunneling section of the settings screen.
///
/// Its own panel rather than a row under Connection: it is a routing policy,
/// not a start-up preference, and sitting beneath "Start with boot" made it
/// read as part of the launch group. The switch writes the same stored
/// preference the split-tunneling screen edits, so the two always agree.
class SplitTunnelPanel extends StatelessWidget {
  const SplitTunnelPanel({
    required this.settings,
    required this.platform,
    required this.onOpenSplitTunneling,
    this.onApplyLive,
    super.key,
  });

  final SettingsController settings;
  final PlatformCapabilities platform;

  /// Opens the per-application split-tunnel screen.
  final VoidCallback onOpenSplitTunneling;

  /// Pushes a changed policy to a running tunnel, when there is one.
  final SplitTunnelLiveApply? onApplyLive;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final split = settings.data.splitTunnel;
    final supported = platform.supportsPerAppSplitTunnelling;
    final summary = [
      split.mode == SplitTunnelMode.include
          ? l10n.get('splitModeInclude')
          : l10n.get('splitModeExclude'),
      l10n.get('splitSelected', {'count': '${split.apps.length}'}),
    ].join(' · ');
    return VgPanel(
      title: l10n.get('settingsSplitTunneling'),
      icon: Icons.call_split_rounded,
      uppercase: true,
      padding: const EdgeInsets.symmetric(vertical: VgSpace.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          VgToggleRow(
            title: l10n.get('splitEnable'),
            subtitle: l10n.get('splitEnableHint'),
            value: split.enabled,
            enabled: supported,
            disabledReason: l10n.get('splitUnsupported'),
            onChanged: (value) => unawaited(_setEnabled(context, value)),
          ),
          if (supported && split.needsAttention)
            Padding(
              padding: const EdgeInsets.only(bottom: VgSpace.sm),
              child: Text(
                l10n.get('splitNeedsApps'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          Divider(color: theme.colorScheme.outline, height: 1),
          VgListRow(
            title: l10n.get('settingsSplitTunnelingApps'),
            subtitle: supported
                ? summary
                : l10n.get('settingsSplitTunnelingHint'),
            leading: Icon(
              Icons.apps_rounded,
              size: VgIcon.sm,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            onTap: onOpenSplitTunneling,
          ),
        ],
      ),
    );
  }

  /// Stores the choice at once, then offers it to a running tunnel.
  ///
  /// Include mode with nothing selected is stored but not applied: the
  /// connection refuses that policy too, and the panel says why.
  Future<void> _setEnabled(BuildContext context, bool value) async {
    settings.update(
      (s) => s.copyWith(splitTunnel: s.splitTunnel.copyWith(enabled: value)),
    );
    final apply = onApplyLive;
    final policy = settings.data.splitTunnel;
    if (apply == null || policy.needsAttention) {
      return;
    }
    final result = await apply(policy);
    if (result == null || !context.mounted) {
      return;
    }
    final l10n = context.l10n;
    final error = result.errorOrNull;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            error == null
                ? l10n.get('splitLiveApplied')
                : l10n.get('splitApplyFailed', {'message': error.message}),
          ),
        ),
      );
  }
}
