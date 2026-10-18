import 'package:flutter/material.dart';
import 'package:phantrix_core/phantrix_core.dart';

import '../../theme/tokens.dart';

/// The meaning a connection control can be in.
///
/// Deliberately narrower than [VpnState]: several machine states map onto one
/// control state, because the user does not need "preparing" and "reconnecting"
/// to look different when both mean "not connected yet, and something is
/// happening".
enum VgTone { idle, working, connected, failed, blocked }

/// The one place the app decides what a connection state *looks* like.
///
/// The orb, the status line, the navigation sidebar and the notes all read
/// their colours from here, so they cannot drift into disagreeing about what
/// "connecting" looks like — which is the failure mode where one element says
/// connected while another still says preparing.
VgTone toneOf(VpnState state) => switch (state) {
  VpnState.disconnected || VpnState.noServerAvailable => VgTone.idle,
  VpnState.preparing ||
  VpnState.connecting ||
  VpnState.reconnecting ||
  VpnState.disconnecting => VgTone.working,
  // Consent is part of the attempt, not a verdict on it: the attempt can
  // still be abandoned from here, so the control reads as in progress and
  // offers Cancel. [VpnState.blocked] keeps the "attention" treatment
  // because that one is a refusal the user has to resolve, and the same
  // colour must not mean both "wait" and "fix this".
  VpnState.permissionRequired => VgTone.working,
  VpnState.connected => VgTone.connected,
  VpnState.error => VgTone.failed,
  VpnState.blocked => VgTone.blocked,
};

/// The colours for a tone.
///
/// Each tone has an accent (the saturated form), a face (a low-chroma fill
/// behind the accent) and a track (the faintest ring). They are three steps of
/// one hue rather than three hexes, so the relationship is obvious and a state
/// still reads as one object.
class VgStatusColors {
  const VgStatusColors({
    required this.accent,
    required this.deep,
    required this.face,
    required this.icon,
  });

  /// The saturated form. Used for strokes, icons and label text.
  final Color accent;

  /// The dark form. Used as a fill *under white text*, such as the orb's face
  /// when it is solid.
  final Color deep;

  /// A low-chroma tint, for a background behind the accent.
  final Color face;

  /// A shape as well as a colour, so state never depends on hue alone.
  final IconData icon;

  static VgStatusColors of(VgTone tone, Brightness brightness) {
    final dark = brightness == Brightness.dark;
    return switch (tone) {
      VgTone.idle => VgStatusColors(
        accent: dark ? VgColors.inkMuted : VgColors.lightInkMuted,
        deep: dark ? VgColors.surfaceHigh : VgColors.lightSurfaceHighest,
        face: dark ? VgColors.surfaceHigh : VgColors.lightSurfaceHighest,
        icon: Icons.power_settings_new_rounded,
      ),
      VgTone.working => VgStatusColors(
        accent: dark ? VgColors.connecting : const Color(0xFF2F4BD0),
        deep: VgColors.connectingDeep,
        face: dark ? const Color(0xFF10182C) : const Color(0xFFE6EBFB),
        icon: Icons.sync_rounded,
      ),
      VgTone.connected => VgStatusColors(
        accent: dark ? VgColors.connected : VgColors.lightConnected,
        deep: dark ? const Color(0xFF0C2B23) : const Color(0xFFD6F3E7),
        face: dark ? const Color(0xFF0C2B23) : const Color(0xFFD6F3E7),
        icon: Icons.shield_rounded,
      ),
      VgTone.failed => VgStatusColors(
        accent: dark ? VgColors.danger : const Color(0xFFC0392B),
        deep: VgColors.dangerDeep,
        face: dark ? const Color(0xFF2A1418) : const Color(0xFFFBE7E6),
        icon: Icons.priority_high_rounded,
      ),
      VgTone.blocked => VgStatusColors(
        accent: dark ? VgColors.warning : const Color(0xFF7A5A12),
        deep: VgColors.warningDeep,
        face: dark ? const Color(0xFF241C0B) : const Color(0xFFFBF0DA),
        icon: Icons.lock_outline_rounded,
      ),
    };
  }
}
