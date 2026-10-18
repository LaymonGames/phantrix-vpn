import 'package:flutter/material.dart';

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

  static OrbPalette forTone(VgTone tone, ThemeData theme) {
    final colors = VgStatusColors.of(tone, theme.brightness);
    final track = theme.brightness == Brightness.dark
        ? VgColors.surfaceHighest
        : VgColors.lightLine;
    return switch (tone) {
      VgTone.idle => OrbPalette(
        colors: colors,
        track: track,
        title: 'Disconnected',
        subtitle: 'Tap to connect',
        action: 'Connect',
        semanticLabel: 'Disconnected. Activate to connect the VPN.',
        hint: 'Double tap to connect the VPN',
      ),
      VgTone.working => OrbPalette(
        colors: colors,
        track: track,
        title: 'Connecting',
        subtitle: 'Tap to cancel',
        action: 'Cancel',
        semanticLabel: 'Connecting. Activate to cancel the connection attempt.',
        hint: 'Double tap to cancel the connection attempt',
      ),
      VgTone.connected => OrbPalette(
        colors: colors,
        track: track,
        title: 'Connected',
        subtitle: 'Tunnel established',
        action: 'Disconnect',
        semanticLabel: 'Connected. The tunnel is established and your traffic is routed through it.',
        hint: 'Double tap to disconnect the VPN',
      ),
      VgTone.failed => OrbPalette(
        colors: colors,
        track: track,
        title: 'Not connected',
        subtitle: 'Tap to try again',
        action: 'Retry',
        semanticLabel: 'Not connected. Activate to try again.',
        hint: 'Double tap to try again',
      ),
      VgTone.blocked => OrbPalette(
        colors: colors,
        track: track,
        title: 'Needs attention',
        subtitle: 'Tap for details',
        action: 'Review',
        semanticLabel: 'Needs your attention before it can connect.',
        hint: 'Double tap to see what is needed',
      ),
    };
  }
}
