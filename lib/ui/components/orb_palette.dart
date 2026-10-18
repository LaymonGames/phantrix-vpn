import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../theme/tokens.dart';
import 'status_style.dart';

/// The wording the orb shows for a tone.
///
/// Split from the colours so the two can be read independently: the colours
/// come from [VgStatusColors], which every other surface in the app also uses,
/// and only this control needs a title, a subtitle and a sentence for a screen
/// reader.
class OrbPalette {
  const OrbPalette({
    required this.colors,
    required this.track,
    required this.title,
    required this.subtitle,
    required this.action,
    required this.semanticLabel,
    required this.hint,
  });

  final VgStatusColors colors;

  /// The ring's resting colour.
  ///
  /// Derived from the theme rather than the status colours: an *unfilled*
  /// ring wants the neutral one, because a ring that is already the accent
  /// colour would claim the state the fill is there to show.
  final Color track;

  final String title;
  final String subtitle;
  final String action;
  final String semanticLabel;

  /// What a screen reader says the gesture will do.
  ///
  /// Phrased per tone rather than derived from [action], because the verb
  /// alone does not always make a sentence: "cancel the VPN" is not what
  /// cancelling does, and an action that has changed from *starting* to
  /// *stopping* must say so before the user presses it.
  final String hint;

  static OrbPalette forTone(VgTone tone, ThemeData theme, L10n l10n) {
    final colors = VgStatusColors.of(tone, theme.brightness);
    final track = theme.brightness == Brightness.dark
        ? VgColors.surfaceHighest
        : VgColors.lightLine;
    return switch (tone) {
      VgTone.idle => OrbPalette(
        colors: colors,
        track: track,
        title: l10n.get('state.disconnected'),
        subtitle: l10n.get('orbTapToConnect'),
        action: l10n.get('connect'),
        semanticLabel: l10n.get('orbSemanticConnect'),
        hint: l10n.get('orbHintConnect'),
      ),
      VgTone.working => OrbPalette(
        colors: colors,
        track: track,
        title: l10n.get('state.connecting'),
        subtitle: l10n.get('orbTapToCancel'),
        action: l10n.get('cancel'),
        semanticLabel: l10n.get('orbSemanticCancel'),
        hint: l10n.get('orbHintCancel'),
      ),
      VgTone.connected => OrbPalette(
        colors: colors,
        track: track,
        title: l10n.get('state.connected'),
        subtitle: l10n.get('sidebarTunnelEstablished'),
        action: l10n.get('disconnect'),
        semanticLabel: l10n.get('orbSemanticDisconnect'),
        hint: l10n.get('orbHintDisconnect'),
      ),
      VgTone.failed => OrbPalette(
        colors: colors,
        track: track,
        title: l10n.get('orbNotConnected'),
        subtitle: l10n.get('sidebarTapToTryAgain'),
        action: l10n.get('retry'),
        semanticLabel: l10n.get('orbSemanticRetry'),
        hint: l10n.get('orbHintRetry'),
      ),
      VgTone.blocked => OrbPalette(
        colors: colors,
        track: track,
        title: l10n.get('state.blocked'),
        subtitle: l10n.get('orbTapForDetails'),
        action: l10n.get('orbReviewAction'),
        semanticLabel: l10n.get('orbSemanticReview'),
        hint: l10n.get('orbHintReview'),
      ),
    };
  }
}
