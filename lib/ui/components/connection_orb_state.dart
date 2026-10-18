part of 'connection_orb.dart';

class _ConnectionOrbState extends State<ConnectionOrb>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: widget.reducedMotion ? VgMotion.slow : VgMotion.orbit,
  );

  /// Whether anything on this orb is actually moving.
  ///
  /// An animation that runs forever on a screen showing nothing happening is
  /// not just untidy: it never lets the frame scheduler go idle, so it costs
  /// battery on a screen that is doing nothing, and it makes any test that
  /// waits for the UI to settle time out. The orb therefore only animates
  /// while a connection is genuinely in progress and no measurable
  /// completion fraction is available.
  bool get _animates =>
      !widget.reducedMotion &&
      widget.state == VgTone.working &&
      widget.progress == null;

  @override
  void initState() {
    super.initState();
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant ConnectionOrb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reducedMotion != widget.reducedMotion) {
      _pulse.duration = widget.reducedMotion ? VgMotion.slow : VgMotion.orbit;
    }
    if (oldWidget.state != widget.state) {
      // Each phase starts at its canonical position rather than inheriting a
      // half-finished connecting sweep.
      _pulse.stop();
      _pulse.value = 0;
    }
    _syncAnimation();
  }

  void _syncAnimation() {
    if (_animates) {
      if (!_pulse.isAnimating) {
        _pulse.repeat();
      }
    } else if (_pulse.isAnimating) {
      // Stopped rather than paused, so a screen showing a static state
      // schedules no frames at all.
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = OrbPalette.forTone(widget.state, theme, L10n.of(context));
    final busy = widget.state == VgTone.working;

    return Semantics(
      button: true,
      enabled: widget.enabled,
      label: palette.semanticLabel,
      hint: palette.hint,
      child: Tooltip(
        message: palette.action,
        child: AnimatedOpacity(
          // A disabled control dims rather than disappears: the user
          // can still see what the button would do.
          duration: VgMotion.fast,
          opacity: widget.enabled ? 1 : 0.45,
          child: MouseRegion(
            cursor: widget.enabled
                ? SystemMouseCursors.click
                : SystemMouseCursors.basic,
            child: GestureDetector(
              onTap: widget.enabled ? widget.onPressed : null,
              child: Semantics(
                excludeSemantics: true,
                child: SizedBox(
                  width: widget.size,
                  height: widget.size,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      // Bloom sits behind the ring and gives the orb depth.
                      if (!widget.reducedMotion && widget.state != VgTone.idle)
                        AnimatedBuilder(
                          animation: _pulse,
                          builder: (context, _) => OrbBloom(
                            color: palette.colors.accent,
                            strength: _bloomStrength(),
                            size: widget.size * 1.36,
                          ),
                        ),
                      OrbTrack(color: palette.track, size: widget.size),
                      OrbRing(
                        color: palette.colors.accent,
                        progress: widget.progress,
                        // The indeterminate arc is a *travelling* arc,
                        // and a frozen arc is a claim the app
                        // cannot support: a quarter-drawn ring says
                        // "a quarter done", and nothing here knows
                        // that. Under reduced motion the ring falls
                        // back to the bare track, so "connecting" is
                        // carried by the colour, the glyph and the
                        // label instead — which is what that
                        // setting is for.
                        pulsing:
                            busy &&
                            widget.progress == null &&
                            !widget.reducedMotion,
                        complete: widget.state == VgTone.connected,
                        size: widget.size,
                        animation: _pulse,
                      ),
                      OrbFace(
                        color: palette.colors.face,
                        edge: palette.colors.accent,
                        state: widget.state,
                        size: widget.size * 0.78,
                      ),
                      OrbIdentity(
                        color: palette.colors.accent,
                        icon: palette.colors.icon,
                        title: palette.title,
                        subtitle: palette.subtitle,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  double _bloomStrength() {
    // Connected glows steadily; working breathes. Idle and failed do not
    // glow, because a glow reads as "active" and neither of those is.
    return switch (widget.state) {
      VgTone.connected => 0.7,
      VgTone.working => 0.4 + 0.25 * _pulse.value,
      _ => 0,
    };
  }
}
