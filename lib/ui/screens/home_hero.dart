import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../vpn/connection_view.dart';
import '../components/connection_orb.dart';
import '../components/status_style.dart';

/// The left column: the control and what a user does next.
///
/// Its surface takes a faint wash of the current state's colour, lit from
/// above, so the whole card — not only the orb — says connected or not.
class HeroPanel extends StatelessWidget {
  const HeroPanel({
    required this.view,
    required this.location,
    required this.reducedMotion,
    required this.onPressed,
    required this.onChooseLocation,
    super.key,
  });

  final ConnectionView view;

  /// Where the tunnel goes (or will go), in words.
  final String location;
  final bool reducedMotion;
  final VoidCallback onPressed;
  final VoidCallback onChooseLocation;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final decor = VgDecor.of(context);
    final tone = toneOf(view.state);
    final stateColor = tone == VgTone.idle
        ? theme.colorScheme.primary
        : VgStatusColors.of(tone, theme.brightness).accent;
    final isDark = theme.brightness == Brightness.dark;
    final wash = tone == VgTone.idle ? 0.05 : (isDark ? 0.14 : 0.10);
    final radius = BorderRadius.circular(VgRadius.xl);
    return AnimatedContainer(
      duration: reducedMotion ? Duration.zero : VgMotion.normal,
      curve: VgMotion.standard,
      decoration: BoxDecoration(
        borderRadius: radius,
        color: theme.colorScheme.surfaceContainerLow,
        border: Border.all(color: decor.cardBorder),
        boxShadow: decor.cardShadow,
        gradient: RadialGradient(
          center: const Alignment(0, -0.9),
          radius: 1.1,
          colors: [
            Color.alphaBlend(
              stateColor.withValues(alpha: wash),
              theme.colorScheme.surfaceContainerLow,
            ),
            theme.colorScheme.surfaceContainerLow,
          ],
        ),
      ),
      padding: const EdgeInsets.fromLTRB(
        VgSpace.lg,
        VgSpace.xxl,
        VgSpace.lg,
        VgSpace.xl,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ConnectionOrb(
            state: tone,
            enabled: true,
            // Connection duration is not connection progress. Until the engine
            // exposes real handshake progress, use the indeterminate sweep.
            progress: null,
            reducedMotion: reducedMotion,
            size: orbSize(context),
            onPressed: onPressed,
          ),
          const SizedBox(height: VgSpace.xl),
          _LocationButton(
            location: location,
            onPressed: onChooseLocation,
          ),
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
    return (available - VgSpace.xl * 2).clamp(180.0, 264.0);
  }
}

/// The destination, as a button: where the next connection goes, and the
/// way to change it.
///
/// There is deliberately no "quick connect" here: the orb above already
/// connects using the chosen location, and a second control for the same
/// action is a trap rather than a convenience.
class _LocationButton extends StatelessWidget {
  const _LocationButton({required this.location, required this.onPressed});

  final String location;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);
    final scheme = theme.colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360),
      child: Material(
        color: scheme.surfaceContainer,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(VgRadius.pill),
          side: BorderSide(color: scheme.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          // Never gated on the connection being idle: picking another
          // location now cancels whatever is in flight and starts the new
          // one, so disabling it mid-attempt would hide exactly the control
          // the feature needs.
          onTap: onPressed,
          child: Semantics(
            button: true,
            child: Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(
                VgSpace.sm,
                VgSpace.sm,
                VgSpace.lg,
                VgSpace.sm,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: scheme.primary.withValues(alpha: 0.14),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.public_rounded,
                      size: 18,
                      color: scheme.primary,
                    ),
                  ),
                  const SizedBox(width: VgSpace.sm),
                  Flexible(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // The action, in words, above the value it
                        // changes: a pill showing only a country name
                        // does not say it can be pressed.
                        Text(
                          l10n.get('chooseALocation'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall,
                        ),
                        Text(
                          location,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: scheme.onSurface,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: VgSpace.xs),
                  Icon(
                    Icons.unfold_more_rounded,
                    size: 18,
                    color: scheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
