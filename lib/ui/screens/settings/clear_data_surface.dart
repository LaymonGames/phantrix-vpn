import 'package:flutter/material.dart';

import '../../../theme/tokens.dart';
import '../../components/surfaces.dart';
import '../../shell.dart';

/// The reset control, kept out of the Advanced panel because it destroys data
/// rather than changing a preference.
class ClearDataSurface extends StatelessWidget {
  const ClearDataSurface({required this.onClear, super.key});

  /// Runs the reset. Injected rather than reached for, so the surface cannot
  /// decide on its own which stores a reset covers.
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return VgSurface(
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(l10n.get('clearData'), style: theme.textTheme.bodyLarge),
                const SizedBox(height: 2),
                Text(
                  l10n.get('clearDataHint'),
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const SizedBox(width: VgSpace.lg),
          OutlinedButton(
            onPressed: () {
              onClear();
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(l10n.get('clearDataDone'))),
              );
            },
            child: Text(l10n.get('clearDataAction')),
          ),
        ],
      ),
    );
  }
}
