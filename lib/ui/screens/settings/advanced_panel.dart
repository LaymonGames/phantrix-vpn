import 'package:flutter/material.dart';

import '../../../theme/tokens.dart';
import '../../components/rows.dart';
import '../../components/surfaces.dart';
import '../../shell.dart';

class AdvancedPanel extends StatelessWidget {
  const AdvancedPanel({
    required this.onOpenDiagnostics,
    super.key,
  });

  final VoidCallback onOpenDiagnostics;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return VgPanel(
      title: l10n.get('settingsAdvanced'),
      icon: Icons.tune_rounded,
      uppercase: true,
      padding: const EdgeInsets.symmetric(vertical: VgSpace.xs),
      child: Column(
        children: [
          VgListRow(
            leading: Icon(
              Icons.insights_outlined,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            title: l10n.get('settingsDiagnostics'),
            subtitle: l10n.get('settingsDiagnosticsHint'),
            onTap: onOpenDiagnostics,
          ),
        ],
      ),
    );
  }
}
