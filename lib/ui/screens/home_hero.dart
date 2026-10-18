import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../theme/tokens.dart';
import '../../vpn/connection_view.dart';
import '../components/connection_orb.dart';
import '../components/status_style.dart';
import '../components/surfaces.dart';

/// The left column: the control and what a user does next.
class HeroPanel extends StatelessWidget {
  const HeroPanel({
    required this.view,
    required this.reducedMotion,
    required this.onPressed,
    required this.onChooseLocation,
    super.key,
  });

  final ConnectionView view;
  final bool reducedMotion;
  final VoidCallback onPressed;
  final VoidCallback onChooseLocation;

  @override
  Widget build(BuildContext context) {
    return VgPanel(
      elevated: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ConnectionOrb(
            state: toneOf(view.state),
            enabled: true,
            // Connection duration is not connection progress. Until the engine
            // exposes real handshake progress, use the indeterminate sweep.
            progress: null,
            reducedMotion: reducedMotion,
            size: orbSize(context),
            onPressed: onPressed,
          ),
          const SizedBox(height: VgSpace.lg),
          _QuickActions(onChooseLocation: onChooseLocation),
        ],
      ),
    );
  }

  /// The orb's diameter.
  ///
  /// Bounded by the *available* width rather than the window's, because on a
  /// desktop this column is a share of the window and the window being wide
  /// says nothing about how wide this column is.
  static double orbSize(BuildContext context) {
    final available =
        MediaQuery.sizeOf(context).width -
        VgSpace.gutter(MediaQuery.sizeOf(context).width);
    // The orb is the first thing on the screen and must not push the
    // server panel off a small window, so it shrinks rather than clipping.
    return (available - VgSpace.xl * 2).clamp(180.0, 260.0);
  }
}

class _QuickActions extends StatelessWidget {
  const _QuickActions({required this.onChooseLocation});

  final VoidCallback onChooseLocation;

  @override
  Widget build(BuildContext context) {
    // There is deliberately no "quick connect" here: the orb above already
    // connects using the recommended server, and a second control for the
    // same action is a trap rather than a convenience. The only thing left
    // to do from this screen is pick where to connect to.
    return Wrap(
      spacing: VgSpace.sm,
      runSpacing: VgSpace.sm,
      alignment: WrapAlignment.center,
      children: [
        FilledButton.tonalIcon(
          // Never gated on the connection being idle: picking another
          // location now cancels whatever is in flight and starts the
          // new one, so disabling it mid-attempt would hide exactly
          // the control the feature needs.
          onPressed: onChooseLocation,
          icon: const Icon(Icons.public_rounded, size: VgIcon.sm),
          label: Text(L10n.of(context).get('chooseALocation')),
        ),
      ],
    );
  }
}
