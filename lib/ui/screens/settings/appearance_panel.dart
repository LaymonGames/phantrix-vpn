import 'package:flutter/material.dart';

import '../../../settings/settings_controller.dart';
import '../../../theme/tokens.dart';
import '../../components/rows.dart';
import '../../components/surfaces.dart';
import '../../shell.dart';

class AppearancePanel extends StatelessWidget {
  const AppearancePanel({required this.settings, super.key});

  final SettingsController settings;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final d = settings.data;
    return VgPanel(
      title: l10n.get('settingsAppearance'),
      icon: Icons.palette_outlined,
      uppercase: true,
      padding: const EdgeInsets.symmetric(vertical: VgSpace.sm),
      child: Column(
        children: [
          VgChoiceRow(
            title: l10n.get('animation'),
            value: d.animationLevel,
            options: {
              'full': () =>
                  settings.update((s) => s.copyWith(animationLevel: 'full')),
              'reduced': () =>
                  settings.update((s) => s.copyWith(animationLevel: 'reduced')),
              'none': () =>
                  settings.update((s) => s.copyWith(animationLevel: 'none')),
            },
          ),
          Divider(
            color: theme.colorScheme.outline,
            height: 1,
            indent: VgSpace.lg,
            endIndent: VgSpace.lg,
          ),
          VgChoiceRow(
            title: l10n.get('language'),
            value: d.language == 'ar' ? 'العربية' : 'English',
            options: {
              'English': () =>
                  settings.update((s) => s.copyWith(language: 'en')),
              'العربية': () =>
                  settings.update((s) => s.copyWith(language: 'ar')),
            },
          ),
        ],
      ),
    );
  }
}
