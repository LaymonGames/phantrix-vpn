import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import '../components/brand.dart';
import '../components/surfaces.dart';
import '../shell.dart';

/// The first-run flow.
///
/// There is no account step, no email step, and no phone step, because there
/// is no account. The privacy notice is not optional, because a user has a
/// right to be told what a public relay can see before they trust one.
///
/// One column on a phone, two on a desktop window: the promise and the notice
/// side by side, because on a wide screen stacking them leaves a column of text
/// in the middle of an empty window.
class OnboardingScreen extends StatelessWidget {
  const OnboardingScreen({required this.onDone, super.key});

  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final wide = MediaQuery.sizeOf(context).width >= VgBreakpoints.twoColumn;

    final mark = Center(child: VgLogo(size: wide ? 76 : 64));
    final heading = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          l10n.get('welcomeTitle'),
          style: wide
              ? theme.textTheme.displaySmall
              : theme.textTheme.headlineMedium,
          textAlign: wide ? TextAlign.start : TextAlign.center,
        ),
        const SizedBox(height: VgSpace.md),
        Text(
          l10n.get('welcomeBody'),
          style: theme.textTheme.bodyLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
          textAlign: wide ? TextAlign.start : TextAlign.center,
        ),
      ],
    );
    final notice = VgPanel(
      title: l10n.get('privacyNoticeTitle'),
      icon: Icons.lock_outline_rounded,
      elevated: true,
      padding: const EdgeInsets.all(VgSpace.lg),
      child: Text(
        l10n.get('privacyNoticeBody'),
        style: theme.textTheme.bodyMedium,
      ),
    );
    final action = SizedBox(
      // Full width on a narrow window so the only action on the screen is
      // easy to hit with a thumb; its natural width on a wide one, so it
      // does not stretch into a bar.
      width: wide ? null : double.infinity,
      child: FilledButton(
        onPressed: onDone,
        child: Text(l10n.get('privacyNoticeAccept')),
      ),
    );

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(VgSpace.xl),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 880),
              child: wide
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        mark,
                        const SizedBox(height: VgSpace.xxl),
                        heading,
                        const SizedBox(height: VgSpace.xxxl),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(child: notice),
                            const SizedBox(width: VgSpace.columnGap),
                            SizedBox(width: 240, child: action),
                          ],
                        ),
                      ],
                    )
                  : Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Spacer(),
                        mark,
                        const SizedBox(height: VgSpace.xxl),
                        heading,
                        const Spacer(),
                        notice,
                        const SizedBox(height: VgSpace.xl),
                        action,
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
