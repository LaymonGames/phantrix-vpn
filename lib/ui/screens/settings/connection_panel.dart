import 'dart:async';

import 'package:flutter/material.dart';

import 'package:phantrix_core/phantrix_core.dart';
import 'package:phantrix_platform/phantrix_platform.dart';

import '../../../settings/settings_controller.dart';
import '../../../theme/tokens.dart';
import '../../components/rows.dart';
import '../../components/surfaces.dart';
import '../../shell.dart';

import 'system_lockdown_row.dart';

class ConnectionPanel extends StatelessWidget {
  const ConnectionPanel({
    required this.settings,
    required this.platform,
    required this.onOpenSystemVpnSettings,
    required this.systemLockdownActive,
    required this.onStartOnBootChanged,
    this.killSwitchBlocking,
    this.onReleaseKillSwitch,
    this.onEngageKillSwitch,
    this.onRefreshKillSwitch,
    super.key,
  });

  final SettingsController settings;
  final PlatformCapabilities platform;
  final VoidCallback onOpenSystemVpnSettings;
  final Future<bool> Function() systemLockdownActive;

  /// Asks the platform to start (or to stop starting) the app at sign-in,
  /// answering whether the machine accepted the choice.
  final Future<bool> Function(bool) onStartOnBootChanged;

  /// Whether the kill switch is blocking traffic right now with no tunnel
  /// up, read live when the setting changes.
  final bool Function()? killSwitchBlocking;

  /// Lifts the kill switch's blocking rules. On Windows this asks for
  /// administrator approval.
  final Future<Result<void>> Function()? onReleaseKillSwitch;

  /// Installs the strict kill switch's rules while nothing is connected, so
  /// choosing strict mode blocks traffic at once.
  final Future<Result<void>> Function()? onEngageKillSwitch;

  /// Re-reads the kill switch's state after the setting changed, so the
  /// home screen's warning matches what the firewall is doing.
  final Future<void> Function()? onRefreshKillSwitch;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final d = settings.data;
    return VgPanel(
      title: l10n.get('settingsConnection'),
      icon: Icons.shield_outlined,
      uppercase: true,
      padding: const EdgeInsets.symmetric(vertical: VgSpace.sm),
      child: Column(
        children: [
          VgChoiceRow(
            title: l10n.get('killSwitch'),
            value: switch (d.killSwitch) {
              KillSwitchMode.off => l10n.get('killSwitchOff'),
              KillSwitchMode.automatic => l10n.get('killSwitchAutomatic'),
              KillSwitchMode.strict => l10n.get('killSwitchStrict'),
            },
            options: {
              l10n.get('killSwitchOff'): () =>
                  unawaited(_setKillSwitch(context, KillSwitchMode.off)),
              l10n.get('killSwitchAutomatic'): () =>
                  unawaited(_setKillSwitch(context, KillSwitchMode.automatic)),
              l10n.get('killSwitchStrict'): () =>
                  unawaited(_setKillSwitch(context, KillSwitchMode.strict)),
            },
            enabled: platform.supportsKillSwitch,
            note: platform.supportsKillSwitch
                ? [
                    switch (d.killSwitch) {
                      KillSwitchMode.off => l10n.get('killSwitchOffHint'),
                      KillSwitchMode.automatic => l10n.get(
                        'killSwitchAutomaticHint',
                      ),
                      KillSwitchMode.strict => l10n.get('killSwitchStrictHint'),
                    },
                  ].join('\n\n')
                : l10n.get('settingsKillSwitchUnsupported'),
          ),
          if (platform.platformName.startsWith('android'))
            SystemLockdownRow(
              systemLockdownActive: systemLockdownActive,
              onOpenSystemVpnSettings: onOpenSystemVpnSettings,
            ),
          Divider(
            color: theme.colorScheme.outline,
            height: 1,
            indent: VgSpace.lg,
            endIndent: VgSpace.lg,
          ),
          VgToggleRow(
            title: l10n.get('startOnBoot'),
            value: d.startOnBoot,
            enabled: platform.supportsBootStart,
            disabledReason: l10n.get('settingsBootStartUnsupported'),
            onChanged: (v) {
              unawaited(_setStartOnBoot(context, v));
            },
          ),
        ],
      ),
    );
  }

  /// Records a kill switch choice, confirming Strict first.
  ///
  /// Strict cuts the internet off whenever Phantrix is not connected, even
  /// after the app closes and across restarts, so it is never one tap away.
  /// Leaving a blocking mode while nothing is connected lifts the rules
  /// that mode left behind; otherwise the user would turn the switch off and
  /// still have no internet.
  ///
  /// The stored choice follows what the machine accepted. If the rules could
  /// not be installed (a declined consent prompt, a refused rule), the row
  /// goes back to the mode it had, and the reason is said: a screen that
  /// shows Strict while nothing is blocking would be claiming protection
  /// this device does not have.
  Future<void> _setKillSwitch(BuildContext context, KillSwitchMode next) async {
    final previous = settings.data.killSwitch;
    if (next == previous) {
      return;
    }
    if (next == KillSwitchMode.strict) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => const _StrictKillSwitchDialog(),
      );
      if (confirmed != true || !context.mounted) {
        return;
      }
    }
    final messenger = ScaffoldMessenger.maybeOf(context);
    final releaseFailedText = context.l10n.get('killSwitchReleaseFailed');
    settings.update((s) => s.copyWith(killSwitch: next));

    final leavesBlocking =
        next == KillSwitchMode.off ||
        (previous == KillSwitchMode.strict && next == KillSwitchMode.automatic);
    final release = onReleaseKillSwitch;
    String? failureText;
    if (leavesBlocking &&
        release != null &&
        (killSwitchBlocking?.call() ?? false)) {
      final result = await release();
      if (result.errorOrNull != null) {
        failureText = releaseFailedText;
      }
    }
    final engage = onEngageKillSwitch;
    if (failureText == null &&
        (next == KillSwitchMode.strict ||
            (next == KillSwitchMode.automatic &&
                previous == KillSwitchMode.off)) &&
        engage != null) {
      final result = await engage();
      failureText = result.errorOrNull?.message;
    }
    if (failureText != null) {
      settings.update((s) => s.copyWith(killSwitch: previous));
    }
    await onRefreshKillSwitch?.call();
    if (failureText != null) {
      messenger
        ?..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(failureText)));
    }
  }

  /// Records the choice only after the platform has accepted it.
  ///
  /// The switch shows the stored preference, so a refusal must leave the
  /// preference alone — otherwise the screen shows a start-up that the
  /// machine never agreed to. A refusal is rare enough to deserve a
  /// sentence, not a screen.
  Future<void> _setStartOnBoot(BuildContext context, bool value) async {
    final applied = await onStartOnBootChanged(value);
    if (applied) {
      settings.update((s) => s.copyWith(startOnBoot: value));
      return;
    }
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.l10n.get('settingsBootStartFailed'))),
    );
  }
}

/// Asks before turning on the strict kill switch.
class _StrictKillSwitchDialog extends StatelessWidget {
  const _StrictKillSwitchDialog();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      icon: const Icon(Icons.gpp_maybe_outlined),
      title: Text(l10n.get('killSwitchStrictConfirmTitle')),
      content: SingleChildScrollView(
        child: Text(l10n.get('killSwitchStrictConfirmBody')),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.get('cancel')),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l10n.get('killSwitchStrictConfirm')),
        ),
      ],
    );
  }
}
