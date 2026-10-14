import 'dart:async';

import 'package:flutter/material.dart';
import 'package:phantrix_core/phantrix_core.dart';

import '../../l10n/strings.dart';

import '../../config/configuration_repository.dart';
import '../../theme/tokens.dart';
import '../../vpn/connection_controller.dart';
import '../components/connection_orb.dart';
import '../components/status_style.dart';
import '../components/surfaces.dart';

/// The connection screen.
///
/// Ordered by what the user needs first: the state of the tunnel, then which
/// server it goes to, then what is actually known about the session, then
/// anything that needs their attention. Everything else is a link away.
///
/// ## Two layouts, one content
///
/// On a phone this is a single scrolling column: the control, then the server,
/// then the facts. On a desktop window the same content becomes two columns —
/// the control holds the left, everything the user reads holds the right — so
/// the window's extra width buys something other than a longer scroll. The
/// content and its order are identical; only the arrangement changes.
class HomeScreen extends StatefulWidget {
	const HomeScreen({
		required this.connection,
		required this.configurations,
		required this.reducedMotion,
		this.selectedCountryCode = 'AUTO',
		required this.onQuickConnect,
		required this.onChooseLocation,
		required this.onManageConfigurations,
		required this.onConnectToConfiguration,
		required this.hasImportedConfigurations,
		super.key,
	});

	final ConnectionController connection;
	final ConfigurationRepository configurations;
	final bool reducedMotion;
	final String selectedCountryCode;
	final Future<void> Function() onQuickConnect;
	final VoidCallback onChooseLocation;
	final VoidCallback onManageConfigurations;
	final Future<void> Function(ImportedConfiguration) onConnectToConfiguration;
	final bool hasImportedConfigurations;

	@override
	State<HomeScreen> createState() => _HomeScreenState();
}

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
														actionLabel: view.canRetry ? 'Try again' : null,
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
																child: _HeroPanel(
																	view: view,
																	reducedMotion: widget.reducedMotion,
																	onPressed: () => _primary(view),
																	onChooseLocation: widget.onChooseLocation,
																	onManageConfigurations: widget.onManageConfigurations,
																),
															),
															const SizedBox(width: VgSpace.columnGap),
															Expanded(
																flex: 6,
																child: _DetailColumn(view: view, l10n: l10n, screen: this),
															),
														],
													)
												else ...[
													_HeroPanel(
														view: view,
														reducedMotion: widget.reducedMotion,
														onPressed: () => _primary(view),
														onChooseLocation: widget.onChooseLocation,
														onManageConfigurations: widget.onManageConfigurations,
													),
													_DetailColumn(view: view, l10n: l10n, screen: this),
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

	List<String> _notesFor(ConnectionView view) {
		final notes = <String>[];
		if (view.lastFallback != null) {
			notes.add(view.lastFallback!);
		}
		// Every platform limitation is shown, not just the first. Showing one
		// and hiding four is how a user discovers the fourth by hitting it.
		notes.addAll(view.platform.limitations.values);
		return notes;
	}
}

/// Everything the user reads: which server, what is known about the session,
/// and anything that needs their attention.
///
/// One widget so the phone and the desktop layout show the same set of blocks
/// in the same order, and so a change to one cannot silently drop a block from
/// the other.
class _DetailColumn extends StatelessWidget {
	const _DetailColumn({
		required this.view,
		required this.l10n,
		required this.screen,
	});

	final ConnectionView view;
	final L10n l10n;
	final _HomeScreenState screen;

	@override
	Widget build(BuildContext context) {
		final screen = this.screen;
		return Column(
			crossAxisAlignment: CrossAxisAlignment.stretch,
			children: [
				VgPanel(
					title: l10n.get('server'),
					icon: Icons.dns_rounded,
					uppercase: true,
					outlined: true,
					child: _ServerPanel(
						view: view,
						selectedCountryCode: screen.widget.selectedCountryCode,
						onChooseLocation: screen.widget.onChooseLocation,
					),
				),
				// The note below claims this build "connects through WireGuard
				// only", so it may appear only while that is true. It was shown
				// unconditionally, telling users to import a file to do the very
				// thing the button beside it already does — on a build whose
				// OpenVPN engine had just been proven to work. Unknown
				// capabilities count as unsupported here, which is how the
				// resolver treats the same condition.
				if (!view.platform.openVpn && !screen.widget.hasImportedConfigurations) ...[
					const SizedBox(height: VgSpace.md),
					VgNote(
						title: l10n.get('publicRelayNoticeTitle'),
						message: l10n.get('publicFeedOpenVpnOnly'),
						icon: Icons.info_outline_rounded,
						action: Align(
							alignment: AlignmentDirectional.centerStart,
							child: TextButton.icon(
								onPressed: view.isBusy
										? null
										: screen.widget.onManageConfigurations,
								icon: const Icon(Icons.upload_file_rounded, size: VgIcon.sm),
								label: Text(l10n.get('importWireGuardConfig')),
							),
						),
					),
				],
				if (view.isConnected || view.isBusy || view.session.startedAt != null) ...[
					const SizedBox(height: VgSpace.lg),
					_SessionPanel(view: view),
				],
				if (screen._notesFor(view).isNotEmpty) ...[
					const SizedBox(height: VgSpace.lg),
					for (final note in screen._notesFor(view)) ...[
						VgNote(message: note),
						const SizedBox(height: VgSpace.sm),
					],
				],
			],
		);
	}
}

/// The left column: the control, its state, and the two things a user does
/// next.
class _HeroPanel extends StatelessWidget {
	const _HeroPanel({
		required this.view,
		required this.reducedMotion,
		required this.onPressed,
		required this.onChooseLocation,
		required this.onManageConfigurations,
	});

	final ConnectionView view;
	final bool reducedMotion;
	final VoidCallback onPressed;
	final VoidCallback onChooseLocation;
	final VoidCallback onManageConfigurations;

	@override
	Widget build(BuildContext context) {
		return VgPanel(
			elevated: true,
			child: Column(
				mainAxisSize: MainAxisSize.min,
				children: [
					ConnectionOrb(
						state: toneOf(view.state),
						enabled: true,
						// Connection duration is not connection progress. Until the engine
						// exposes real handshake progress, use the indeterminate sweep.
						progress: null,
						reducedMotion: reducedMotion,
						size: orbSize(context),
						onPressed: onPressed,
					),
					const SizedBox(height: VgSpace.lg),
					_StatusLine(view: view),
					const SizedBox(height: VgSpace.lg),
					_QuickActions(
						onChooseLocation: onChooseLocation,
						onManageConfigurations: onManageConfigurations,
					),
				],
			),
		);
	}

	/// The orb's diameter.
	///
	/// Bounded by the *available* width rather than the window's, because on a
	/// desktop this column is a share of the window and the window being wide
	/// says nothing about how wide this column is.
	static double orbSize(BuildContext context) {
		final available = MediaQuery.sizeOf(context).width - VgSpace.gutter(
			MediaQuery.sizeOf(context).width,
		);
		// The orb is the first thing on the screen and must not push the
		// server panel off a small window, so it shrinks rather than clipping.
		return (available - VgSpace.xl * 2).clamp(180.0, 260.0);
	}
}

/// One sentence saying what the tunnel is doing, in the app's own colour.
///
/// Under the orb rather than above it: the orb already says the state, and a
/// second box repeating it higher up the screen is what makes a dashboard feel
/// like a form.
class _StatusLine extends StatelessWidget {
	const _StatusLine({required this.view});

	final ConnectionView view;

	@override
	Widget build(BuildContext context) {
		final theme = Theme.of(context);
		final colors = VgStatusColors.of(toneOf(view.state), theme.brightness);
		return Container(
			padding: const EdgeInsets.symmetric(
				horizontal: VgSpace.lg,
				vertical: VgSpace.md,
			),
			decoration: BoxDecoration(
				// A tint of the state colour rather than a neutral well, so the
				// sentence and the orb read as one object.
				color: colors.accent.withValues(alpha: 0.09),
				borderRadius: BorderRadius.circular(VgRadius.md),
				border: Border.all(color: colors.accent.withValues(alpha: 0.20)),
			),
			child: Row(
				children: [
					Icon(colors.icon, size: VgIcon.sm, color: colors.accent),
					const SizedBox(width: VgSpace.md),
					Expanded(
						child: Text(
							view.statusMessage,
							textAlign: TextAlign.center,
							style: theme.textTheme.bodyMedium?.copyWith(
								color: theme.colorScheme.onSurface,
							),
						),
					),
				],
			),
		);
	}
}

class _ServerPanel extends StatelessWidget {
	const _ServerPanel({
		required this.view,
		required this.selectedCountryCode,
		required this.onChooseLocation,
	});

	final ConnectionView view;
	final String selectedCountryCode;
	final VoidCallback onChooseLocation;

	@override
	Widget build(BuildContext context) {
		final theme = Theme.of(context);
		final l10n = L10n.of(context);
		final rawLabel = view.selectedLabel;
		final selectedLabel = selectedCountryCode == 'AUTO'
				? l10n.get('automaticLocation')
				: GeoDatabase.nameOf(selectedCountryCode, l10n.languageCode);
		// Prefer the active tunnel's destination while it is connecting or
		// connected. Otherwise show the saved preference, including after a
		// failed attempt; a previous session's server must not override the
		// location the user just selected.
		final label = (view.isConnected || view.isBusy) && rawLabel != null
				? ((GeoDatabase.byIso2(rawLabel) != null || GeoDatabase.byIso3(rawLabel) != null)
						? GeoDatabase.nameOf(rawLabel, l10n.languageCode)
						: rawLabel)
				: selectedLabel;
		return VgSurface(
			onTap: onChooseLocation,
			padding: EdgeInsets.zero,
			child: Row(
				children: [
					const SizedBox(width: VgSpace.md),
					Container(
						width: 38,
						height: 38,
						decoration: BoxDecoration(
							color: theme.colorScheme.primary.withValues(alpha: 0.12),
							borderRadius: BorderRadius.circular(VgRadius.sm),
						),
						child: Icon(
							view.selectedLabel == null
									? Icons.public_rounded
									: Icons.dns_rounded,
							size: VgIcon.md,
							color: theme.colorScheme.primary,
						),
					),
					const SizedBox(width: VgSpace.md),
					Expanded(
						child: Column(
							crossAxisAlignment: CrossAxisAlignment.start,
							mainAxisSize: MainAxisSize.min,
							children: [
								Text(
									label,
									maxLines: 1,
									overflow: TextOverflow.ellipsis,
									style: theme.textTheme.titleMedium,
								),
								const SizedBox(height: 2),
								Text(
									view.selectedLabel == null
											? l10n.get('savedLocationHint')
											: l10n.get('tapToChangeLocation'),
									maxLines: 1,
									overflow: TextOverflow.ellipsis,
									style: theme.textTheme.bodySmall,
								),
							],
						),
					),
					const Icon(Icons.chevron_right_rounded, size: VgIcon.md),
					const SizedBox(width: VgSpace.sm),
				],
			),
		);
	}
}

class _SessionPanel extends StatelessWidget {
	const _SessionPanel({required this.view});

	final ConnectionView view;

	@override
	Widget build(BuildContext context) {
		final session = view.session;
		// Nothing is shown before a connection has been verified. An empty
		// panel full of "Not tested" is noise; the honest thing when there is
		// no session is to say nothing.
		if (!view.isConnected && !view.isBusy && session.startedAt == null) {
			return const SizedBox.shrink();
		}
		final theme = Theme.of(context);
		final duration = session.duration;
		final connected = VgStatusColors.of(
			toneOf(view.state),
			theme.brightness,
		);

		return VgPanel(
			title: 'This session',
			icon: Icons.insights_rounded,
			uppercase: true,
			child: Column(
				crossAxisAlignment: CrossAxisAlignment.stretch,
				children: [
					Row(
						children: [
							Expanded(
								child: VgStat(
									// Never call it "connected for" before there is a
									// session to count from: a build-up panel that says
									// "Connected for —" while the tunnel is still
									// coming up claims something that has not happened.
									label: view.isConnected ? 'Connected for' : 'Session',
									value: duration == null ? '—' : _duration(duration),
									icon: Icons.schedule_rounded,
									tone: view.isConnected ? connected.accent : null,
								),
							),
							const SizedBox(width: VgSpace.sm),
							Expanded(
								child: VgStat(
									label: 'Downloaded',
									value: _bytes(session.rxBytes),
									icon: Icons.south_rounded,
								),
							),
							const SizedBox(width: VgSpace.sm),
							Expanded(
								child: VgStat(
									label: 'Uploaded',
									value: _bytes(session.txBytes),
									icon: Icons.north_rounded,
								),
							),
						],
					),
					const SizedBox(height: VgSpace.md),
					VgSurface(
						outlined: true,
						padding: const EdgeInsets.symmetric(
							horizontal: VgSpace.md,
							vertical: VgSpace.xs,
						),
						child: Column(
							children: [
								VgInfoRow(
									label: 'Public IP',
									// The address is only ever the one the leak
									// check actually read. When it has not been read,
									// it says so rather than showing a placeholder
									// that looks like an address.
									value: session.assignedIpv4 ?? 'Not verified',
									icon: Icons.public_rounded,
									monospace: session.assignedIpv4 != null,
								),
								Divider(color: theme.colorScheme.outline, height: 1),
								VgInfoRow(
									label: 'Protocol',
									value: session.protocolLabel ?? 'WireGuard',
									icon: Icons.shield_outlined,
								),
								Divider(color: theme.colorScheme.outline, height: 1),
								VgInfoRow(
									label: 'IPv6',
									// The policy, not a claim about what is
									// happening on the wire: "blocked" is a setting
									// this app enforces, and saying so precisely is
									// honest where "your IPv6 is safe" would not be.
									value: _ipv6Label(view),
									icon: Icons.hub_outlined,
								),
							],
						),
					),
				],
			),
		);
	}

	static String _ipv6Label(ConnectionView view) => switch (view.ipv6Policy) {
		Ipv6Mode.block => 'Blocked',
		Ipv6Mode.allow => 'Allowed',
		Ipv6Mode.preferTunnel => 'Through tunnel',
	};

	static String _duration(Duration d) {
		final h = d.inHours;
		final m = d.inMinutes.remainder(60);
		final s = d.inSeconds.remainder(60);
		final padded = s.toString().padLeft(2, '0');
		if (h > 0) {
			return '${h}h ${m.toString().padLeft(2, '0')}m';
		}
		if (m > 0) {
			return '$m:$padded';
		}
		return '0:$padded';
	}

	static String _bytes(int count) {
		if (count <= 0) {
			return '0 B';
		}
		if (count < 1024) {
			return '$count B';
		}
		if (count < 1024 * 1024) {
			return '${(count / 1024).toStringAsFixed(1)} KB';
		}
		if (count < 1024 * 1024 * 1024) {
			return '${(count / (1024 * 1024)).toStringAsFixed(1)} MB';
		}
		return '${(count / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
	}
}

class _QuickActions extends StatelessWidget {
	const _QuickActions({
		required this.onChooseLocation,
		required this.onManageConfigurations,
	});

	final VoidCallback onChooseLocation;
	final VoidCallback onManageConfigurations;

	@override
	Widget build(BuildContext context) {
		// Wrapped rather than forced into a row or a column. Each button sizes
		// to its own label, so neither can be truncated, and the pair moves to
		// a second line on its own when the window is too narrow for both. A
		// layout chosen by measuring the window up front gets this wrong at
		// exactly the widths that matter, because it is the *text* that decides
		// whether the buttons fit, not the window.
		//
		// There is deliberately no "quick connect" here: the orb above already
		// connects using the recommended server, and a second control for the
		// same action is a trap rather than a convenience.
		return Wrap(
			spacing: VgSpace.sm,
			runSpacing: VgSpace.sm,
			alignment: WrapAlignment.center,
			children: [
				FilledButton.tonalIcon(
					// Never gated on the connection being idle: picking another
					// location now cancels whatever is in flight and starts the
					// new one, so disabling it mid-attempt would hide exactly
					// the control the feature needs.
					onPressed: onChooseLocation,
					icon: const Icon(Icons.public_rounded, size: VgIcon.sm),
					label: const Text('Choose a location'),
				),
				OutlinedButton.icon(
					// Neither of these starts or stops anything: both only
					// navigate, and the screens they open have their own
					// controls for the connection. Disabling them mid-attempt
					// would say there is something wrong with looking at the
					// server list while a tunnel is coming up — which is
					// exactly how a user changes server.
					onPressed: onManageConfigurations,
					icon: const Icon(Icons.add_link_rounded, size: VgIcon.sm),
					label: const Text('Import'),
				),
			],
		);
	}
}