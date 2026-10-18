library;

import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../theme/tokens.dart';
import 'orb_face.dart';
import 'orb_palette.dart';
import 'orb_rings.dart';
import 'status_style.dart';

part 'connection_orb_state.dart';

/// The primary connect control.
///
/// ## What it shows, and what it deliberately does not
///
/// The ring is the honest part. It shows a measured fraction only when a caller
/// has a real quantity to report; otherwise it uses a travelling arc while the
/// engine is working. It never turns elapsed time into fake progress, and it
/// never shows a completed ring unless the tunnel is genuinely verified.
///
/// When the tunnel is up, the orb reports *tunnel established*. It does not
/// claim the user's traffic is protected on its own: that claim belongs to the
/// state machine, which requires a fresh handshake and a changed public address
/// before it will say "connected", and the label here is derived from the same
/// state so the two cannot disagree.
///
/// ## Motion
///
/// Every animation is suppressed when the user has asked for reduced motion,
/// because a pulsing element that fills a large part of the screen is exactly
/// what that setting exists for. The state is still fully legible without it —
/// colour, icon and label all carry it.
class ConnectionOrb extends StatefulWidget {
  const ConnectionOrb({
    required this.state,
    required this.onPressed,
    this.enabled = true,
    this.progress,
    this.reducedMotion = false,
    this.size = 220,
    super.key,
  });

  final VgTone state;
  final VoidCallback? onPressed;
  final bool enabled;

  /// A 0..1 quantity, or null when there is nothing to measure.
  ///
  /// Only meaningful for [VgTone.working] when the caller has a measurable
  /// quantity. Null makes the ring indeterminate instead of fabricating a
  /// percentage from elapsed connection time.
  final double? progress;

  final bool reducedMotion;
  final double size;

  @override
  State<ConnectionOrb> createState() => _ConnectionOrbState();
}
