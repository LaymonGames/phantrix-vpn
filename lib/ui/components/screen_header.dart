import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../theme/tokens.dart';
import 'brand.dart';

/// The compact header shown above a screen on a phone.
///
/// Carries the screen's name and, when one is open over the tabs, a back
/// arrow — so a secondary screen always shows both where it sits and how to
/// leave it.
class VgScreenHeader extends StatelessWidget {
  const VgScreenHeader({
    required this.title,
    this.onBack,
    this.trailing,
    super.key,
  });

  final String title;

  /// When set, a back arrow replaces the brand mark.
  final VoidCallback? onBack;

  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        VgSpace.lg,
        VgSpace.sm,
        VgSpace.lg,
        VgSpace.sm,
      ),
      child: Row(
        children: [
          if (onBack != null)
            IconButton(
              onPressed: onBack,
              tooltip: L10n.of(context).get('back'),
              visualDensity: VisualDensity.compact,
              color: theme.colorScheme.onSurfaceVariant,
              icon: const Icon(Icons.arrow_back_rounded, size: VgIcon.md),
            )
          else
            const VgLogo(size: 26),
          const SizedBox(width: VgSpace.md),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleLarge,
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}
