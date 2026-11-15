import 'package:flutter/material.dart';

import '../../../settings/settings_controller.dart';
import '../../../theme/tokens.dart';
import '../../components/rows.dart';
import '../../components/surfaces.dart';
import '../../shell.dart';
import 'accent_picker.dart';

class AppearancePanel extends StatelessWidget {
  const AppearancePanel({required this.settings, super.key});

  final SettingsController settings;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final d = settings.data;
    Widget divider() => Divider(
      color: theme.colorScheme.outline,
      height: 1,
      indent: VgSpace.lg,
      endIndent: VgSpace.lg,
    );
    return VgPanel(
      title: l10n.get('settingsAppearance'),
      icon: Icons.palette_outlined,
      uppercase: true,
      padding: const EdgeInsets.symmetric(vertical: VgSpace.sm),
      child: Column(
        children: [
          VgChoiceRow(
            title: l10n.get('theme'),
            value: switch (d.themeMode) {
              'light' => l10n.get('themeLight'),
              'dark' => l10n.get('themeDark'),
              _ => l10n.get('themeSystem'),
            },
            options: {
              l10n.get('themeSystem'): () =>
                  settings.update((s) => s.copyWith(themeMode: 'system')),
              l10n.get('themeLight'): () =>
                  settings.update((s) => s.copyWith(themeMode: 'light')),
              l10n.get('themeDark'): () =>
                  settings.update((s) => s.copyWith(themeMode: 'dark')),
            },
          ),
          divider(),
          AccentPicker(
            value: d.accentColor,
            onChanged: (value) =>
                settings.update((s) => s.copyWith(accentColor: value)),
          ),
          divider(),
          VgChoiceRow(
            title: l10n.get('animation'),
            value: switch (d.animationLevel) {
              'reduced' => l10n.get('animationReduced'),
              'none' => l10n.get('animationNone'),
              _ => l10n.get('animationFull'),
            },
            options: {
              l10n.get('animationFull'): () =>
                  settings.update((s) => s.copyWith(animationLevel: 'full')),
              l10n.get('animationReduced'): () =>
                  settings.update((s) => s.copyWith(animationLevel: 'reduced')),
              l10n.get('animationNone'): () =>
                  settings.update((s) => s.copyWith(animationLevel: 'none')),
            },
          ),
          divider(),
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
