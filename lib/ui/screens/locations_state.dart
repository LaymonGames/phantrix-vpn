part of 'locations_screen.dart';

class _LocationsScreenState extends State<LocationsScreen> {
  final _search = TextEditingController();
  String _query = '';
  String _sort = 'latency';
  bool _mapVisible = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<CountryEntry> get _visible {
    final query = _query.trim();
    final needle = query.toLowerCase();
    final all = buildCountryEntries(widget.snapshot);
    final filtered = needle.isEmpty
        ? all
        : all.where((e) {
            // Match on both names so the field works in either
            // language, and on the raw code.
            return e.code.toLowerCase() == needle ||
                e.nameFor('en').toLowerCase().contains(needle) ||
                e.nameFor('ar').contains(query);
          }).toList();
    return sortCountryEntries(filtered, _sort);
  }

  /// The one notice the directory may carry, or null when it needs none.
  ///
  /// The public feed speaks OpenVPN, so a build that cannot start one has
  /// nothing usable on this screen. Saying so before the tap is the whole
  /// reason the capability is passed down rather than guessed at.
  Widget? _directoryNotice(BuildContext context) {
    final l10n = context.l10n;
    final servers = widget.snapshot.servers;
    if (servers.isEmpty) {
      return null;
    }
    final allOpenVpn = servers.every(
      (server) => server.protocol == ProtocolKind.openVpn,
    );
    if (allOpenVpn && !widget.openVpnSupported) {
      return VgNote(
        message: l10n.get('publicFeedOpenVpnOnly'),
        icon: Icons.info_outline_rounded,
        color: Theme.of(context).colorScheme.tertiary,
      );
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final entries = _visible;
    final snapshot = widget.snapshot;
    final query = _query.trim().toLowerCase();
    final showAutomatic =
        query.isEmpty ||
        'auto'.contains(query) ||
        l10n.get('automaticLocation').toLowerCase().contains(query);
    final directoryNotice = _directoryNotice(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        VgContentColumn(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              VgPanel(
                padding: const EdgeInsets.all(VgSpace.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: _search,
                      onChanged: (v) => setState(() => _query = v),
                      decoration: InputDecoration(
                        hintText: l10n.get('searchCountries'),
                        prefixIcon: const Icon(
                          Icons.search_rounded,
                          size: VgIcon.md,
                        ),
                      ),
                    ),
                    const SizedBox(height: VgSpace.sm),
                    // A Wrap, not a Row: the sort controls plus the map
                    // toggle do not fit a narrow phone, and wrapping
                    // keeps them usable at a 2x text scale.
                    Wrap(
                      spacing: VgSpace.sm,
                      runSpacing: VgSpace.sm,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        _FilterChip(
                          label: l10n.get('fastest'),
                          selected: _sort == 'latency',
                          onSelected: () => setState(() => _sort = 'latency'),
                        ),
                        _FilterChip(
                          label: l10n.get('sortByName'),
                          selected: _sort == 'name',
                          onSelected: () => setState(() => _sort = 'name'),
                        ),
                        _FilterChip(
                          label: l10n.get('sortByCount'),
                          selected: _sort == 'count',
                          onSelected: () => setState(() => _sort = 'count'),
                        ),
                        IconButton(
                          tooltip: l10n.get('toggleMap'),
                          isSelected: _mapVisible,
                          onPressed: () =>
                              setState(() => _mapVisible = !_mapVisible),
                          icon: const Icon(Icons.public_rounded),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (_mapVisible) ...[
                const SizedBox(height: VgSpace.md),
                VgSurface(
                  padding: EdgeInsets.zero,
                  clip: false,
                  child: SizedBox(
                    // Taller on a window with room for it: a map
                    // squashed to a strip is decoration, and this is
                    // meant to be read.
                    height:
                        MediaQuery.sizeOf(context).width >=
                            VgBreakpoints.twoColumn
                        ? 320
                        : 170,
                    child: GlobeMap(servers: mapServersOf(snapshot.servers)),
                  ),
                ),
              ],
              const SizedBox(height: VgSpace.md),
              DirectoryBanner(
                snapshot: snapshot,
                isRefreshing: widget.isRefreshing,
                onRefresh: widget.onRefresh,
              ),
              if (directoryNotice != null) ...[
                const SizedBox(height: VgSpace.sm),
                directoryNotice,
              ],
            ],
          ),
        ),
        Expanded(
          child: entries.isEmpty && !showAutomatic
              ? _EmptyState(
                  hasServers: !snapshot.isEmpty,
                  filtering: _query.trim().isNotEmpty,
                )
              : RefreshIndicator(
                  onRefresh: widget.onRefresh ?? () async {},
                  child: VgContentColumn(
                    child: ListView.separated(
                      padding: const EdgeInsets.only(
                        top: VgSpace.xs,
                        bottom: VgSpace.xxl,
                      ),
                      itemCount: entries.length + (showAutomatic ? 1 : 0),
                      separatorBuilder: (context, index) =>
                          const SizedBox(height: VgSpace.sm),
                      itemBuilder: (context, index) {
                        if (showAutomatic && index == 0) {
                          return AutoLocationCard(
                            selected: widget.selectedCountryCode == 'AUTO',
                            label: l10n.get('automaticLocation'),
                            detail: l10n.get('automaticLocationHint'),
                            onSelected: () => widget.onCountrySelected('AUTO'),
                          );
                        }
                        final entryIndex = index - (showAutomatic ? 1 : 0);
                        final entry = entries[entryIndex];
                        return CountryCard(
                          entry: entry,
                          selected: entry.code == widget.selectedCountryCode,
                          onSelected: widget.onCountrySelected,
                        );
                      },
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}
