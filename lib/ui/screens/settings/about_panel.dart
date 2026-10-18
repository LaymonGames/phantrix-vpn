import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../notices/generated_third_party_notices.dart';
import '../../../notices/third_party_notices.dart';
import '../../../theme/tokens.dart';
import '../../components/rows.dart';
import '../../components/surfaces.dart';
import '../../shell.dart';

/// The About panel: who made this, which build it is, and where the licences
/// live.
///
/// Nothing here is typed in. The version is read from the generated notice
/// inventory, which the generator reads out of `pubspec.yaml`, so the number
/// on screen cannot drift from the number the build was stamped with — and
/// the CI freshness gate fails when the two disagree. There used to be a
/// hardcoded `'1.0.0'` here, which was already wrong: the package version is
/// `1.0.0+1`.
class AboutPanel extends StatelessWidget {
  const AboutPanel({required this.onOpenLicenses, super.key});

  /// Opens the licences and credits screen.
  final VoidCallback onOpenLicenses;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final app = ThirdPartyNotices.app(thirdPartyNotices);
    return VgPanel(
      title: l10n.get('settingsAbout'),
      icon: Icons.info_outline_rounded,
      uppercase: true,
      padding: const EdgeInsets.symmetric(vertical: VgSpace.xs),
      child: Column(
        children: [
          const SizedBox(height: VgSpace.xs),
          // Stated values rather than links, so they get the panel's
          // label/value primitive and sit on the same grid as every other
          // fact in the app.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: VgSpace.lg),
            child: Column(
              children: [
                VgInfoRow(
                  label: l10n.get('aboutCreator'),
                  value: 'Laymon Games',
                ),
                VgInfoRow(
                  label: l10n.get('aboutVersion'),
                  value: app?.version ?? l10n.get('aboutVersionUnknown'),
                  monospace: true,
                ),
              ],
            ),
          ),
          const SizedBox(height: VgSpace.xs),
          VgListRow(
            leading: const Icon(Icons.gavel_outlined),
            title: l10n.get('settingsLicenses'),
            subtitle: l10n.get('settingsLicensesHint'),
            onTap: onOpenLicenses,
            showDivider: true,
          ),
          VgListRow(
            leading: const Icon(Icons.workspace_premium_outlined),
            title: l10n.get('aboutPortfolio'),
            subtitle: 'laymongames.github.io/portfolio',
            onTap: () => _openPortfolio(context),
          ),
        ],
      ),
    );
  }

  /// Opens the portfolio, which is a credit rather than a required link, so a
  /// failure is reported in a snack bar instead of being swallowed.
  Future<void> _openPortfolio(BuildContext context) async {
    var opened = false;
    try {
      opened = await launchUrl(
        Uri.parse('https://laymongames.github.io/portfolio/'),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      opened = false;
    }
    if (opened || !context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.l10n.get('portfolioOpenFailed'))),
    );
  }
}
