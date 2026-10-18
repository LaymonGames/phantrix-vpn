part of 'shell.dart';

class AppShell extends StatefulWidget {
  const AppShell({
    required this.destinations,
    required this.navigation,
    this.statusFooter,
    super.key,
  });

  final List<Destination> destinations;
  final AppNavigationLike navigation;

  /// The live connection summary shown in the sidebar's footer.
  ///
  /// Supplied by the caller rather than read from a controller here, so the
  /// shell stays a layout and has no idea what a VPN is.
  final Widget? statusFooter;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.navigation,
      builder: (context, _) {
        final destinations = widget.destinations;
        // Measured during build rather than cached in a field. A cached
        // value can disagree with the window being laid out in, and the
        // symptom - a phone bottom bar on a desktop window - reads as a
        // layout bug rather than the state bug it is.
        final wide = MediaQuery.sizeOf(context).width >= VgBreakpoints.sidebar;
        // Clamped rather than trusted: the destination list is rebuilt
        // on a settings change, and a shorter list must not leave the
        // shell pointing past its own end.
        final index = widget.navigation.index.clamp(
          0,
          (destinations.length - 1).clamp(0, destinations.length - 1),
        );
        final current = destinations[index];

        // The three primary destinations are the tabs. A secondary
        // destination (import/manage configs, diagnostics, privacy,
        // licenses) is opened over them, highlights its parent section,
        // and offers a back arrow — so the bar never grows past three and
        // a secondary screen never strands the user.
        final primary = destinations
            .where((d) => d.isPrimary)
            .toList(growable: false);
        final secondary = destinations
            .where((d) => !d.isPrimary && d.parentId == current.parentId)
            .toList(growable: false);
        final backTo = current.parentId;
        final sectionId = backTo ?? current.id;

        void goBack() {
          if (backTo == null) {
            return;
          }
          final parent = destinations.indexWhere((d) => d.id == backTo);
          if (parent >= 0) {
            widget.navigation.select(parent);
          }
        }

        void goTo(int i) {
          if (i >= 0 && i < primary.length) {
            widget.navigation.select(destinations.indexOf(primary[i]));
          }
        }

        // The sidebar lists the tabs, plus whichever secondary screens
        // currently sit under the one in view. On a desktop window there
        // is room for them, and showing them here is what lets the user
        // walk away from Diagnostics with the keyboard instead of
        // hunting for a back arrow.
        final sidebarItems = <VgNavItem>[
          for (final d in primary)
            VgNavItem(
              id: d.id,
              label: d.label,
              icon: d.icon,
              selectedIcon: d.selectedIcon,
              selected: d.id == sectionId && backTo == null,
            ),
          for (final d in secondary)
            VgNavItem(
              id: d.id,
              label: d.label,
              icon: d.icon,
              selectedIcon: d.selectedIcon,
              selected: d.id == current.id,
              indented: true,
            ),
        ];

        final tabItems = <VgNavItem>[
          for (final d in primary)
            VgNavItem(
              id: d.id,
              label: d.label,
              icon: d.icon,
              selectedIcon: d.selectedIcon,
              selected: d.id == sectionId,
            ),
        ];

        return Scaffold(
          body: SafeArea(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (wide)
                  VgSidebar(
                    items: sidebarItems,
                    onSelect: (id) {
                      final target = destinations.indexWhere((d) => d.id == id);
                      if (target >= 0) {
                        widget.navigation.select(target);
                      }
                    },
                    status: widget.statusFooter,
                  ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Only on the compact layout. With a
                      // sidebar every destination's name is
                      // already on screen and permanently
                      // highlighted, so a title repeating it
                      // adds nothing and floats above the
                      // content unaligned with anything.
                      if (!wide)
                        VgScreenHeader(
                          title: current.label,
                          onBack: backTo == null ? null : goBack,
                        ),
                      Expanded(
                        child: KeyedSubtree(
                          // Keyed by id, not index, so switching
                          // screens rebuilds and removing one
                          // does not leave the wrong screen up.
                          key: ValueKey(current.id),
                          child: current.builder(context),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // The bar is always the three tabs — including on a secondary
          // screen, where it highlights the section that screen belongs
          // to. That is the way out alongside the header's back arrow.
          bottomNavigationBar: wide
              ? null
              : VgTabBar(
                  items: tabItems,
                  onSelect: (id) {
                    final target = primary.indexWhere((d) => d.id == id);
                    goTo(target);
                  },
                ),
        );
      },
    );
  }
}
