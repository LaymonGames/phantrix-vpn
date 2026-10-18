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
    super.key,
  });

  final SettingsController settings;
  final PlatformCapabilities platform;
  final VoidCallback onOpenSystemVpnSettings;
  final Future<bool> Function() systemLockdownActive;

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
              l10n.get('killSwitchOff'): () => settings.update(
                (s) => s.copyWith(killSwitch: KillSwitchMode.off),
              ),
              l10n.get('killSwitchAutomatic'): () => settings.update(
                (s) => s.copyWith(killSwitch: KillSwitchMode.automatic),
              ),
              l10n.get('killSwitchStrict'): () => settings.update(
                (s) => s.copyWith(killSwitch: KillSwitchMode.strict),
              ),
            },
            enabled: platform.supportsKillSwitch,
            note: platform.supportsKillSwitch
                ? null
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
            disabledReason:
                'This platform cannot start the app on system boot.',
            onChanged: (v) =>
                settings.update((s) => s.copyWith(startOnBoot: v)),
          ),
        ],
      ),
    );
  }
}
