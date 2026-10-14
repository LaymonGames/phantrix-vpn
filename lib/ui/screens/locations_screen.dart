import 'package:flutter/material.dart';

import 'package:phantrix_core/phantrix_core.dart';

import '../shell.dart';
import '../widgets/globe_map.dart';
import '../../theme/tokens.dart';
import '../components/rows.dart';
import '../components/surfaces.dart';

/// One country row, derived from real server data.
///
/// Every field here comes from a [DirectorySnapshot]. Nothing is defaulted to
/// a plausible-looking number: an unmeasured latency is null and is rendered
/// as a dash.
class CountryEntry {
	CountryEntry({
		required this.code,
		required this.servers,
		required this.bestLatencyMs,
		required this.protocols,
		required this.trust,
	});

	/// ISO 3166-1 alpha-2, upper case.
	final String code;

	/// Every server currently held for this country, including unreachable
	/// ones. The UI says how many of them are usable rather than implying the
	/// whole set will work.
	final List<VpnServer> servers;

	/// The best latency among servers that actually reported one, or null when
	/// none did.
	final int? bestLatencyMs;

	/// The protocols available here.
	final Set<ProtocolKind> protocols;

	/// The weakest trust level present, so a public relay is never presented
	/// with the same badge as a project-operated server.
	final TrustLevel trust;

	int get serverCount => servers.length;

	int get usableCount => servers.where((s) => s.status.isUsable).length;

	/// The country name in [languageCode], falling back to the code.
	String nameFor(String languageCode) {
		final name = GeoDatabase.nameOf(code, languageCode);
		return name.isEmpty ? code : name;
	}

	String get flag => GeoDatabase.flagOf(code);
}

/// Builds country rows from a directory snapshot.
///
/// Kept as a pure function so it can be tested without a widget tree, and so
/// the "one country per real server" rule has a single definition.
List<CountryEntry> buildCountryEntries(DirectorySnapshot snapshot) {
	final entries = <CountryEntry>[];
	for (final group in snapshot.byCountry.entries) {
		if (group.value.isEmpty) {
			continue;
		}
		final code = group.key.toUpperCase();

		// Only latencies that were actually measured count. A null in the
		// list must not become 0, which would sort to the top.
		final measured = group.value
				.where((s) => s.metrics.latencyMs != null)
				.map((s) => s.metrics.latencyMs!)
				.toList(growable: false);
		measured.sort();

		entries.add(
			CountryEntry(
				code: code,
				servers: List.unmodifiable(group.value),
				bestLatencyMs: measured.isEmpty ? null : measured.first,
				protocols: Set.unmodifiable(group.value.map((s) => s.protocol)),
				trust: weakestTrust(group.value.map((s) => s.trustLevel)),
			),
		);
	}
	return entries;
}

TrustLevel weakestTrust(Iterable<TrustLevel> levels) {
	// publicRelay is the weakest value the enum can hold for our purposes;
	// start at the strongest so the weakest wins regardless of declaration order.
	var weakest = TrustLevel.projectVerified;
	for (final level in levels) {
		if (level.index > weakest.index) {
			weakest = level;
		}
	}
	return weakest;
}

/// Converts servers into map pins.
///
/// A server with no coordinates is dropped rather than pinned at (0, 0),
/// which would place it off the coast of Africa and be actively misleading.
List<MapServer> mapServersOf(List<VpnServer> servers) => [
	for (final server in servers)
		if (server.latitude != null && server.longitude != null)
			MapServer(
				latitude: server.latitude!,
				longitude: server.longitude!,
				label: server.city ?? server.countryCode,
				countryCode: server.countryCode,
			),
];

/// Sorts country rows for display.
List<CountryEntry> sortCountryEntries(List<CountryEntry> entries, String mode) {
	final sorted = List<CountryEntry>.of(entries);
	switch (mode) {
		case 'name':
			sorted.sort((a, b) => a.nameFor('en').compareTo(b.nameFor('en')));
		case 'count':
			sorted.sort((a, b) => b.serverCount.compareTo(a.serverCount));
		default:
			// Unmeasured countries sort last rather than pretending to be fast.
			sorted.sort((a, b) {
				final la = a.bestLatencyMs;
				final lb = b.bestLatencyMs;
				if (la == null && lb == null) {
					return a.nameFor('en').compareTo(b.nameFor('en'));
				}
				if (la == null) {
					return 1;
				}
				if (lb == null) {
					return -1;
				}
				return la.compareTo(lb);
			});
	}
	return sorted;
}

/// The country browser.
///
/// The list is built from the live server inventory. Before the first
/// refresh, and after a refresh that found nothing, the screen says which of
/// those it is — it never falls back to a built-in list of countries with
/// invented server counts and latencies.
///
/// The search field and the filters sit in a panel above the list rather than
/// loose on the background, so the controls read as one thing you operate
/// rather than three things you happened to scroll past.
class LocationsScreen extends StatefulWidget {
	const LocationsScreen({
		required this.onCountrySelected,
		required this.snapshot,
		this.selectedCountryCode = 'AUTO',
		this.hasImportedConfigurations = false,
		this.openVpnSupported = false,
		this.onManageConfigurations,
		this.onRefresh,
		this.isRefreshing = false,
		super.key,
	});

	final void Function(String countryCode) onCountrySelected;

	/// The current directory state. Supplied by the caller so the screen stays
	/// a pure function of its inputs and needs no provider plumbing of its own.
	final DirectorySnapshot snapshot;
	final String selectedCountryCode;
	final bool hasImportedConfigurations;

	/// Whether this build can start an OpenVPN tunnel itself.
	///
	/// The notice below claims the build "connects through WireGuard only";
	/// it may appear only while that claim is true. Defaults to false, so an
	/// unread capability counts as unsupported — the same conservative
	/// reading the connection resolver applies to a server it cannot prove
	/// this build can start.
	final bool openVpnSupported;

	final VoidCallback? onManageConfigurations;

	final Future<void> Function()? onRefresh;

	final bool isRefreshing;

	@override
	State<LocationsScreen> createState() => _LocationsScreenState();
}

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

	@override
	Widget build(BuildContext context) {
		final l10n = context.l10n;
		final entries = _visible;
		final snapshot = widget.snapshot;
		final query = _query.trim().toLowerCase();
		final showAutomatic = query.isEmpty ||
				'auto'.contains(query) ||
				l10n.get('automaticLocation').toLowerCase().contains(query);

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
										height: MediaQuery.sizeOf(context).width >=
												VgBreakpoints.twoColumn
											? 320
											: 170,
										child: GlobeMap(servers: mapServersOf(snapshot.servers)),
									),
								),
							],
							const SizedBox(height: VgSpace.md),
							_DirectoryBanner(
								snapshot: snapshot,
								isRefreshing: widget.isRefreshing,
								onRefresh: widget.onRefresh,
							),
							// Two claims must both hold before this notice may appear:
							// the feed offers only OpenVPN, *and* this build cannot
							// start it. The second conjunct was missing, so a build
							// that could run every server on this screen still told
							// the user to import a WireGuard file first.
							if (snapshot.servers.isNotEmpty &&
								snapshot.servers.every(
									(server) => server.protocol == ProtocolKind.openVpn,
								) &&
								!widget.openVpnSupported) ...[
								const SizedBox(height: VgSpace.sm),
								VgNote(
									message: l10n.get('publicFeedOpenVpnOnly'),
									icon: Icons.info_outline_rounded,
									color: Theme.of(context).colorScheme.tertiary,
									action: Align(
										alignment: AlignmentDirectional.centerStart,
										child: TextButton.icon(
											onPressed: widget.onManageConfigurations,
											icon: const Icon(
												Icons.upload_file_rounded,
												size: VgIcon.sm,
											),
											label: Text(
												widget.hasImportedConfigurations
														? l10n.get('manageConfigurations')
														: l10n.get('importWireGuardConfig'),
											),
										),
									),
								),
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
												return _AutoLocationCard(
													selected: widget.selectedCountryCode == 'AUTO',
													label: l10n.get('automaticLocation'),
													detail: l10n.get('automaticLocationHint'),
													onSelected: () => widget.onCountrySelected('AUTO'),
												);
											}
											final entryIndex = index - (showAutomatic ? 1 : 0);
											final entry = entries[entryIndex];
											return _CountryCard(
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

class _AutoLocationCard extends StatelessWidget {
	const _AutoLocationCard({
		required this.selected,
		required this.label,
		required this.detail,
		required this.onSelected,
	});

	final bool selected;
	final String label;
	final String detail;
	final VoidCallback onSelected;

	@override
	Widget build(BuildContext context) {
		final theme = Theme.of(context);
		return VgSurface(
			onTap: onSelected,
			// The accent bar rather than a tinted fill: automatic is the
			// default, and it should be marked the way the app marks every
			// other selection, not as a warning.
			accent: selected ? theme.colorScheme.primary : null,
			padding: EdgeInsets.zero,
			child: VgListRow(
				contentPadding: const EdgeInsets.symmetric(
					horizontal: VgSpace.md,
					vertical: VgSpace.sm,
				),
				leading: _LeadingBadge(
					icon: Icons.auto_awesome_rounded,
					selected: selected,
				),
				title: label,
				subtitle: detail,
				trailing: Icon(
					selected ? Icons.check_circle_rounded : Icons.chevron_right_rounded,
					color: selected
							? theme.colorScheme.primary
							: theme.colorScheme.onSurfaceVariant,
					size: VgIcon.md,
				),
			),
		);
	}
}

/// The icon well at the head of a row.
///
/// Shared by the automatic card and the country rows so a selected row and an
/// unselected one differ in exactly one way — the colour of this badge — and
/// nothing else on the row has to be restyled to keep them matched.
class _LeadingBadge extends StatelessWidget {
	const _LeadingBadge({required this.icon, required this.selected, this.text});

	final IconData icon;
	final bool selected;
	final String? text;

	@override
	Widget build(BuildContext context) {
		final theme = Theme.of(context);
		final color = selected
				? theme.colorScheme.primary
				: theme.colorScheme.onSurfaceVariant;
		return Container(
			width: 38,
			height: 38,
			alignment: Alignment.center,
			decoration: BoxDecoration(
				color: color.withValues(alpha: 0.12),
				borderRadius: BorderRadius.circular(VgRadius.sm),
			),
			child: text == null
					? Icon(icon, size: VgIcon.md, color: color)
					: Text(text!, style: const TextStyle(fontSize: 20)),
		);
	}
}

class _CountryCard extends StatelessWidget {
	const _CountryCard({
		required this.entry,
		required this.selected,
		required this.onSelected,
	});

	final CountryEntry entry;
	final bool selected;
	final void Function(String countryCode) onSelected;

	@override
	Widget build(BuildContext context) {
		final theme = Theme.of(context);
		final l10n = context.l10n;
		// A dash, not a number: latency that was never measured is unknown.
		final latency = entry.bestLatencyMs;
		final latencyText = latency == null ? '—' : '$latency ms';

		return VgSurface(
			onTap: () => onSelected(entry.code),
			accent: selected ? theme.colorScheme.primary : null,
			padding: EdgeInsets.zero,
			child: VgListRow(
				contentPadding: const EdgeInsets.symmetric(
					horizontal: VgSpace.md,
					vertical: VgSpace.sm,
				),
				leading: _LeadingBadge(
					icon: Icons.dns_rounded,
					selected: selected,
					text: entry.flag,
				),
				title: l10n.isRtl ? entry.nameFor('ar') : entry.nameFor('en'),
				subtitle:
						'${entry.serverCount} ${l10n.get('serversAvailable')} · '
						'${entry.protocols.map((p) => p.shortLabel).join(', ')}',
				trailing: Row(
					mainAxisSize: MainAxisSize.min,
					children: [
						if (entry.trust == TrustLevel.publicRelay)
							Tooltip(
								message: l10n.get('publicRelayWarning'),
								child: Icon(
									Icons.gpp_maybe_outlined,
									size: VgIcon.sm,
									color: theme.colorScheme.onSurfaceVariant,
								),
							),
						const SizedBox(width: VgSpace.sm),
						// The one figure in the row that decides an ordering,
						// given tabular figures so the column of them lines up
						// down the list instead of shimmering.
						Text(
							latencyText,
							style: theme.textTheme.labelMedium?.copyWith(
								fontFeatures: VgType.tabular,
							),
						),
						if (selected) ...[
							const SizedBox(width: VgSpace.sm),
							Icon(
								Icons.check_circle_rounded,
								color: theme.colorScheme.primary,
								size: VgIcon.md,
							),
						],
					],
				),
			),
		);
	}
}

/// Says what the directory currently is: never refreshed, refreshing,
/// current, stale, or broken. A screen that shows an empty list without
/// saying why is indistinguishable from a bug.
class _DirectoryBanner extends StatelessWidget {
	const _DirectoryBanner({
		required this.snapshot,
		required this.isRefreshing,
		this.onRefresh,
	});

	final DirectorySnapshot snapshot;
	final bool isRefreshing;
	final Future<void> Function()? onRefresh;

	@override
	Widget build(BuildContext context) {
		final l10n = context.l10n;
		final errors = snapshot.providerErrors.values.toList(growable: false);

		if (isRefreshing) {
			return VgBusy(l10n.get('refreshingServers'), compact: true);
		}

		if (errors.isNotEmpty) {
			return _Banner(
				icon: Icons.cloud_off_rounded,
				message: l10n.get('serverListUnavailable'),
				detail: errors.first.message,
				tone: _BannerTone.warning,
				action: onRefresh == null
						? null
						: TextButton(onPressed: onRefresh, child: Text(l10n.get('retry'))),
			);
		}

		return switch (snapshot.state) {
			DirectoryState.empty => _Banner(
					icon: Icons.refresh_rounded,
					message: l10n.get('noServerListYet'),
					detail: l10n.get('noServerListHint'),
					tone: _BannerTone.neutral,
					action: onRefresh == null
							? null
							: TextButton(onPressed: onRefresh, child: Text(l10n.get('refresh'))),
				),
			DirectoryState.stale => _Banner(
					icon: Icons.schedule_rounded,
					message: l10n.get('serverListStale'),
					tone: _BannerTone.warning,
					action: onRefresh == null
							? null
							: TextButton(onPressed: onRefresh, child: Text(l10n.get('refresh'))),
				),
			DirectoryState.offlineUsingCache => _Banner(
					icon: Icons.cloud_off_rounded,
					message: l10n.get('showingCachedList'),
					tone: _BannerTone.warning,
				),
			DirectoryState.cacheCorrupt => _Banner(
					icon: Icons.warning_amber_rounded,
					message: l10n.get('cachedListDamaged'),
					tone: _BannerTone.warning,
					action: onRefresh == null
							? null
							: TextButton(onPressed: onRefresh, child: Text(l10n.get('refresh'))),
				),
			DirectoryState.fresh => _Banner(
					icon: Icons.cloud_done_rounded,
					message: l10n.get('serverListCurrent'),
					detail: '${snapshot.serverCount} ${l10n.get('serversAvailable')}',
					tone: _BannerTone.positive,
				),
		};
	}
}

enum _BannerTone { neutral, positive, warning }

class _Banner extends StatelessWidget {
	const _Banner({
		required this.icon,
		required this.message,
		required this.tone,
		this.detail,
		this.action,
	});

	final IconData icon;
	final String message;
	final String? detail;
	final _BannerTone tone;
	final Widget? action;

	@override
	Widget build(BuildContext context) {
		final theme = Theme.of(context);
		final color = switch (tone) {
			_BannerTone.neutral => theme.colorScheme.onSurfaceVariant,
			_BannerTone.positive => theme.colorScheme.primary,
			_BannerTone.warning => theme.colorScheme.tertiary,
		};
		return Row(
			children: [
				Icon(icon, size: VgIcon.sm, color: color),
				const SizedBox(width: VgSpace.sm),
				// The text is the state; the icon and colour only support it,
				// so nothing here is conveyed by colour alone.
				Expanded(
					child: Column(
						crossAxisAlignment: CrossAxisAlignment.start,
						mainAxisSize: MainAxisSize.min,
						children: [
							Text(message, style: theme.textTheme.bodySmall),
							if (detail != null)
								Text(detail!, style: theme.textTheme.bodySmall),
						],
					),
				),
				?action,
			],
		);
	}
}

class _EmptyState extends StatelessWidget {
	const _EmptyState({required this.hasServers, required this.filtering});

	/// True when servers exist but the filter excluded them all.
	final bool hasServers;

	final bool filtering;

	@override
	Widget build(BuildContext context) {
		final l10n = context.l10n;
		final theme = Theme.of(context);
		return Center(
			child: Padding(
				padding: const EdgeInsets.symmetric(horizontal: 40),
				child: Column(
					mainAxisSize: MainAxisSize.min,
					children: [
						Icon(
							filtering ? Icons.search_off_rounded : Icons.public_off_rounded,
							size: 32,
							color: theme.colorScheme.onSurfaceVariant,
						),
						const SizedBox(height: VgSpace.md),
						Text(
							filtering || hasServers
									? l10n.get('noServerInCountry')
									: l10n.get('noServersFound'),
							textAlign: TextAlign.center,
							style: theme.textTheme.bodyMedium,
						),
					],
				),
			),
		);
	}
}

class _FilterChip extends StatelessWidget {
	const _FilterChip({required this.label, required this.selected, required this.onSelected});

	final String label;
	final bool selected;
	final VoidCallback onSelected;

	@override
	Widget build(BuildContext context) => VgSegment(
		label: label,
		selected: selected,
		onTap: onSelected,
		// No tick: a sort filter has no value to assert. It is marked by its
		// fill and its border, which is enough to read at a glance and leaves
		// the tick to mean "this is the value" wherever a value exists.
		selectedIcon: null,
	);
}