import 'package:flutter/material.dart';

import 'package:phantrix_core/phantrix_core.dart';

import '../../../settings/settings_controller.dart';
import '../../../theme/tokens.dart';
import '../../components/rows.dart';
import '../../components/surfaces.dart';
import '../../shell.dart';

class PrivacyPanel extends StatelessWidget {
  const PrivacyPanel({required this.settings, super.key});

  final SettingsController settings;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final d = settings.data;
    return VgPanel(
      title: l10n.get('settingsPrivacy'),
      icon: Icons.lock_outline_rounded,
      uppercase: true,
      padding: const EdgeInsets.symmetric(vertical: VgSpace.sm),
      child: Column(
        children: [
          VgChoiceRow(
            title: l10n.get('ipv6'),
            value: switch (d.ipv6) {
              Ipv6Mode.block => l10n.get('ipv6Block'),
              Ipv6Mode.preferTunnel => l10n.get('ipv6Prefer'),
              Ipv6Mode.allow => l10n.get('ipv6Allow'),
            },
            options: {
              l10n.get('ipv6Block'): () =>
                  settings.update((s) => s.copyWith(ipv6: Ipv6Mode.block)),
              l10n.get('ipv6Prefer'): () => settings.update(
                (s) => s.copyWith(ipv6: Ipv6Mode.preferTunnel),
              ),
              l10n.get('ipv6Allow'): () =>
                  settings.update((s) => s.copyWith(ipv6: Ipv6Mode.allow)),
            },
            note: d.ipv6 == Ipv6Mode.allow
                ? 'Allowing IPv6 without a route through the tunnel is a '
                      'known leak. The setting is labelled "may leak" for that '
                      'reason.'
                : null,
          ),
        ],
      ),
    );
  }
}
