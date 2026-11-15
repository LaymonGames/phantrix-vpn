part of 'home_screen.dart';

class _HomeScreenState extends State<HomeScreen> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // Only while connected. A ticker that runs for the whole session is
    // 86 400 needless rebuilds a day, and it keeps the session timer
    // visibly wrong for up to a second after connecting.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) {
        return;
      }
      if (widget.connection.currentView.isConnected) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<ConnectionView>(
      initialData: widget.connection.currentView,
      stream: widget.connection.views,
      builder: (context, snapshot) {
        final view = snapshot.data ?? widget.connection.currentView;
        final l10n = L10n.of(context);
        // The scroll view spans the page so the mouse wheel works over the
        // margins too; only its content is held to the dashboard measure.
        final location = _locationLabel(
          view,
          widget.selectedCountryCode,
          l10n,
        );
        // The scroll view spans the page so the mouse wheel works over the
        // margins too; only its content is held to the dashboard measure.
        return VgScrollColumn(
          wide: true,
          builder: (context, insets) => SingleChildScrollView(
            padding: insets.copyWith(top: VgSpace.xl, bottom: VgSpace.xl),
            child: LayoutBuilder(
              builder: (context, inner) {
                final twoColumn =
                    MediaQuery.sizeOf(context).width >=
                    VgBreakpoints.twoColumn;
                final hero = HeroPanel(
                  view: view,
                  location: location,
                  reducedMotion: widget.reducedMotion,
                  onPressed: () => _primary(view),
                  onChooseLocation: widget.onChooseLocation,
                );
                final details = _DetailColumn(
                  view: view,
                  l10n: l10n,
                  settings: widget.settings,
                  selectedCountryCode: widget.selectedCountryCode,
                  onChooseLocation: widget.onChooseLocation,
                  onOpenSettings: widget.onOpenSettings,
                );
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _StatusHeader(view: view, location: location),
                    const SizedBox(height: VgSpace.xl),
                    // An error spans the full width on every layout: it is
                    // the one thing on this screen that must not be
                    // missed, and squeezing it into a narrow column is how
                    // a failure gets scrolled past.
                    if (view.errorMessage != null) ...[
                      VgErrorCard(
                        message: view.errorMessage!,
                        code: view.errorCode,
                        actionLabel: view.canRetry
                            ? l10n.get('tryAgain')
                            : null,
                        onAction: view.canRetry
                            ? () => unawaited(widget.connection.retry())
                            : null,
                      ),
                      const SizedBox(height: VgSpace.lg),
                    ],
                    // Full width for the same reason: "no internet" with no
                    // visible cause is the worst outcome a kill switch can
                    // produce.
                    if (view.killSwitchBlocking) ...[
                      _KillSwitchCard(
                        strict: view.killSwitch.strict,
                        onUnblock: widget.connection.releaseKillSwitch,
                      ),
                      const SizedBox(height: VgSpace.lg),
                    ],
                    if (twoColumn)
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(flex: 5, child: hero),
                          const SizedBox(width: VgSpace.columnGap),
                          Expanded(flex: 6, child: details),
                        ],
                      )
                    else ...[
                      hero,
                      const SizedBox(height: VgSpace.lg),
                      details,
                    ],
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }

  void _primary(ConnectionView view) {
    // One control, both directions. Connected *or* on its way up: the same
    // press brings it down. A press during an attempt cancels it rather
    // than being ignored — "Connecting…" with a button that does nothing
    // is the one outcome a user cannot act on, and the attempt can be
    // abandoned at any point it has reached.
    if (view.isConnected || view.isBusy) {
      unawaited(widget.connection.cancel());
    } else {
      unawaited(widget.onQuickConnect());
    }
  }
}
