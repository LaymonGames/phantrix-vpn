import 'package:flutter/material.dart';

import '../../theme/tokens.dart';

/// The large title at the top of a page on a desktop window.
///
/// On a phone the shell's header already names the page, so this draws
/// nothing there; on a desktop the sidebar shows where you are but nothing
/// on the page itself did, which left settings starting with a card pressed
/// against the top of the window.
class VgPageTitle extends StatelessWidget {
  const VgPageTitle({required this.title, this.subtitle, super.key});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.sizeOf(context).width < VgBreakpoints.sidebar) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: VgSpace.lg, bottom: VgSpace.lg),
      child: Semantics(
        header: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: VgSpace.xxs),
              Text(subtitle!, style: theme.textTheme.bodyMedium),
            ],
          ],
        ),
      ),
    );
  }
}
