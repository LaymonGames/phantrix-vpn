import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import 'brand.dart';
import 'status_style.dart';
import 'surfaces.dart';

/// The live connection summary shown in the sidebar footer.
///
/// Deliberately carries no elapsed timer. A ticking clock in the chrome would
/// rebuild the sidebar once a second for the whole session to report a figure
/// that is already on the dashboard — battery spent on a number nobody is
/// looking at.
class VgConnectionSummary extends StatelessWidget {
  const VgConnectionSummary({
    required this.tone,
    required this.label,
    this.detail,
    super.key,
  });

  /// The connection state this summary is reporting.
  final VgTone tone;
  final String label;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Outlined, not filled: the sidebar behind it is already a raised
    // surface, so a card the same colour would be invisible — the footer
    // would read as text floating against the sidebar rather than as a
    // panel that can be lifted out of it.
    return VgSurface(
      outlined: true,
      padding: const EdgeInsets.all(VgSpace.md),
      child: Row(
        children: [
          VgStatusDot(tone: tone),
          const SizedBox(width: VgSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                if (detail != null)
                  Text(
                    detail!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
