import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../theme/tokens.dart';
import '../../components/rows.dart';
import '../../components/surfaces.dart';
import '../../shell.dart';

class AboutPanel extends StatelessWidget {
  const AboutPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return VgPanel(
      title: l10n.get('settingsAbout'),
      icon: Icons.info_outline_rounded,
      uppercase: true,
      padding: const EdgeInsets.symmetric(vertical: VgSpace.xs),
      child: Column(
        children: [
          VgListRow(
            title: l10n.get('aboutPortfolio'),
            subtitle: 'laymongames.github.io/portfolio',
            onTap: () async {
              var opened = false;
              try {
                opened = await launchUrl(
                  Uri.parse('https://laymongames.github.io/portfolio/'),
                );
              } catch (_) {
                opened = false;
              }
              if (!opened && context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(l10n.get('portfolioOpenFailed'))),
                );
              }
            },
            showDivider: true,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: VgSpace.lg,
              vertical: VgSpace.md,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.get('aboutCreator'),
                    style: theme.textTheme.bodyLarge,
                  ),
                ),
                Text('Laymon Games', style: theme.textTheme.bodyMedium),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: VgSpace.lg,
              vertical: VgSpace.md,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.get('aboutVersion'),
                    style: theme.textTheme.bodyLarge,
                  ),
                ),
                Text('1.0.0', style: theme.textTheme.bodyMedium),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
