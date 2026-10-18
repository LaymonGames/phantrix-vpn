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
        return VgContentColumn(
          wide: true,
          child: LayoutBuilder(
            // Laid out to fill the window rather than stacked from the
            // top. On a short window it scrolls; on a tall one the hero
            // sits around a third of the way down instead of leaving a
            // void beneath it, which is what a top-aligned column does
            // on every desktop display.
            builder: (context, constraints) => SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: constraints.maxHeight - VgSpace.lg,
                ),
                child: LayoutBuilder(
                  builder: (context, inner) {
                    final twoColumn =
                        MediaQuery.sizeOf(context).width >=
                        VgBreakpoints.twoColumn;
                    return Column(
                      // Centred rather than spread. `spaceEvenly`
                      // puts the same gap between every pair of
                      // elements, which on a tall window pulls the
                      // status line away from the control it
                      // describes and makes the screen read as
                      // loose rather than calm.
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // An error spans the full width on every
                        // layout: it is the one thing on this screen
                        // that must not be missed, and squeezing it
                        // into a narrow column is how a failure gets
                        // scrolled past.
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
                        if (twoColumn)
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                flex: 5,
                                child: HeroPanel(
                                  view: view,
                                  reducedMotion: widget.reducedMotion,
                                  onPressed: () => _primary(view),
                                  onChooseLocation: widget.onChooseLocation,
                                ),
                              ),
                              const SizedBox(width: VgSpace.columnGap),
                              Expanded(
                                flex: 6,
                                child: _DetailColumn(
                                  view: view,
                                  l10n: l10n,
                                  selectedCountryCode:
                                      widget.selectedCountryCode,
                                  onChooseLocation: widget.onChooseLocation,
                                ),
                              ),
                            ],
                          )
                        else ...[
                          HeroPanel(
                            view: view,
                            reducedMotion: widget.reducedMotion,
                            onPressed: () => _primary(view),
                            onChooseLocation: widget.onChooseLocation,
                          ),
                          _DetailColumn(
                            view: view,
                            l10n: l10n,
                            selectedCountryCode: widget.selectedCountryCode,
                            onChooseLocation: widget.onChooseLocation,
                          ),
                        ],
                      ],
                    );
                  },
                ),
              ),
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
