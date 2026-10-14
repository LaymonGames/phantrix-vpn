import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import 'brand.dart';
import 'status_style.dart';
import 'surfaces.dart';

/// One entry in a navigation surface.
class VgNavItem {
	const VgNavItem({
		required this.id,
		required this.label,
		required this.icon,
		required this.selectedIcon,
		this.selected = false,
		this.indented = false,
	});

	final String id;
	final String label;
	final IconData icon;
	final IconData selectedIcon;

	/// Whether this is the destination currently on screen.
	///
	/// A secondary destination marks its *parent* section selected rather than
	/// marking itself, so the highlight never claims a tab the user is not on.
	final bool selected;

	/// Rendered inset and with a back chevron — a screen opened over the tabs.
	final bool indented;
}

/// The desktop navigation rail.
///
/// A real sidebar rather than a Material [NavigationRail]: the shell needs a
/// header with the wordmark and a footer with the live connection state, and
/// both need to sit *outside* the item list. A sidebar that reports whether
/// the tunnel is up, from every screen, is the whole point of having space
/// for one.
class VgSidebar extends StatelessWidget {
	const VgSidebar({
		required this.items,
		required this.onSelect,
		this.status,
		this.width = 248,
		super.key,
	});

	final List<VgNavItem> items;
	final void Function(String id) onSelect;

	/// The live connection summary in the footer.
	final Widget? status;

	final double width;

	@override
	Widget build(BuildContext context) {
		final theme = Theme.of(context);
		final isDark = theme.brightness == Brightness.dark;
		return Container(
			width: width,
			decoration: BoxDecoration(
				color: theme.colorScheme.surfaceContainerLow,
				// A single hairline rather than a shadow: the sidebar is flush
				// with the content beside it, and a border is what separates
				// two planes that touch.
				border: BorderDirectional(
					end: BorderSide(color: theme.colorScheme.outline),
				),
				boxShadow: isDark ? null : VgShadow.forSidebar(Colors.black),
			),
			child: Column(
				crossAxisAlignment: CrossAxisAlignment.stretch,
				children: [
					const Padding(
						padding: EdgeInsets.fromLTRB(
							VgSpace.lg,
							VgSpace.xl,
							VgSpace.lg,
							VgSpace.lg,
						),
						child: VgBrand(size: 30),
					),
					Padding(
						padding: const EdgeInsets.symmetric(horizontal: VgSpace.md),
						child: Divider(color: theme.colorScheme.outline, height: 1),
					),
					const SizedBox(height: VgSpace.md),
					for (final item in items)
						Padding(
							padding: const EdgeInsets.symmetric(
								horizontal: VgSpace.md,
								vertical: 2,
							),
							child: _SidebarRow(
								item: item,
								onTap: () => onSelect(item.id),
							),
						),
					const Spacer(),
					if (status != null)
						Padding(
							padding: const EdgeInsets.all(VgSpace.md),
							child: status,
						),
				],
			),
		);
	}
}

class _SidebarRow extends StatefulWidget {
	const _SidebarRow({required this.item, required this.onTap});

	final VgNavItem item;
	final VoidCallback onTap;

	@override
	State<_SidebarRow> createState() => _SidebarRowState();
}

class _SidebarRowState extends State<_SidebarRow> {
	bool _hovered = false;
	bool _focused = false;

	@override
	Widget build(BuildContext context) {
		final theme = Theme.of(context);
		final scheme = theme.colorScheme;
		final item = widget.item;
		final selected = item.selected;

		// A real focusable control rather than a bare gesture detector, so the
		// sidebar can be walked with Tab and activated with Enter or Space on
		// Windows, and the focused row shows a visible ring.
		return Semantics(
			button: true,
			selected: selected,
			label: item.label,
			excludeSemantics: true,
			child: Tooltip(
				message: item.label,
				waitDuration: const Duration(milliseconds: 600),
				child: FocusableActionDetector(
					mouseCursor: SystemMouseCursors.click,
					onShowHoverHighlight: (v) => setState(() => _hovered = v),
					onShowFocusHighlight: (v) => setState(() => _focused = v),
					actions: <Type, Action<Intent>>{
						ActivateIntent: CallbackAction<ActivateIntent>(
							onInvoke: (_) {
								widget.onTap();
								return null;
							},
						),
					},
					child: GestureDetector(
						behavior: HitTestBehavior.opaque,
						onTap: widget.onTap,
						child: AnimatedContainer(
							duration: VgMotion.fast,
							curve: VgMotion.standard,
							padding: EdgeInsetsDirectional.fromSTEB(
								item.indented ? VgSpace.xl : VgSpace.sm,
								VgSpace.sm + 3,
								VgSpace.md,
								VgSpace.sm + 3,
							),
							decoration: BoxDecoration(
								color: selected
										? scheme.primary.withValues(alpha: 0.12)
										: _hovered
										? scheme.onSurface.withValues(alpha: 0.05)
										: Colors.transparent,
								borderRadius: BorderRadius.circular(VgRadius.md),
								border: Border.all(
									color: _focused ? scheme.primary : Colors.transparent,
									width: 2,
								),
							),
							child: Row(
								children: [
									// The selection marker: a short bar on the leading
									// edge, so the current section reads by shape as well
									// as by tint.
									AnimatedContainer(
										duration: VgMotion.fast,
										curve: VgMotion.standard,
										width: 3,
										height: selected ? 18 : 0,
										margin: const EdgeInsetsDirectional.only(end: VgSpace.sm),
										decoration: BoxDecoration(
											color: scheme.primary,
											borderRadius: BorderRadius.circular(VgRadius.pill),
										),
									),
									if (item.indented) ...[
										const Icon(
											Icons.subdirectory_arrow_right_rounded,
											size: VgIcon.sm,
											color: VgColors.inkFaint,
										),
										const SizedBox(width: VgSpace.xs),
									],
									Icon(
										selected ? item.selectedIcon : item.icon,
										size: VgIcon.md,
										color: selected ? scheme.primary : scheme.onSurfaceVariant,
									),
									const SizedBox(width: VgSpace.md),
									Expanded(
										child: Text(
											item.label,
											maxLines: 1,
											overflow: TextOverflow.ellipsis,
											style: theme.textTheme.labelLarge?.copyWith(
												color: selected
														? scheme.onSurface
														: scheme.onSurfaceVariant,
												fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
											),
										),
									),
								],
							),
						),
					),
				),
			),
		);
	}
}

/// The phone navigation bar.
///
/// Three destinations, always, because three labels survive an accessibility
/// text scale that four or six do not — and the screens that would have been
/// tabs are one tap away from Settings instead.
class VgTabBar extends StatelessWidget {
	const VgTabBar({required this.items, required this.onSelect, super.key});

	final List<VgNavItem> items;
	final void Function(String id) onSelect;

	@override
	Widget build(BuildContext context) {
		final theme = Theme.of(context);
		final scheme = theme.colorScheme;
		return Container(
			decoration: BoxDecoration(
				color: scheme.surfaceContainerLow,
				border: Border(top: BorderSide(color: scheme.outline)),
			),
			child: SafeArea(
				top: false,
				child: SizedBox(
					height: 64,
					child: Row(
						children: [
							for (final item in items)
								Expanded(
									child: _TabButton(
										item: item,
										onTap: () => onSelect(item.id),
									),
								),
						],
					),
				),
			),
		);
	}
}

class _TabButton extends StatelessWidget {
	const _TabButton({required this.item, required this.onTap});

	final VgNavItem item;
	final VoidCallback onTap;

	@override
	Widget build(BuildContext context) {
		final theme = Theme.of(context);
		final scheme = theme.colorScheme;
		final selected = item.selected;
		final color = selected ? scheme.primary : scheme.onSurfaceVariant;
		return Semantics(
			button: true,
			selected: selected,
			child: InkWell(
				onTap: onTap,
				child: Column(
					mainAxisAlignment: MainAxisAlignment.center,
					children: [
						Stack(
							alignment: Alignment.bottomCenter,
							children: [
								// The indicator is a short bar above the icon
								// rather than a pill behind it: at this height a
								// pill clips the label, and the bar still reads
								// at a glance.
								AnimatedContainer(
									duration: VgMotion.fast,
									curve: VgMotion.standard,
									height: 2,
									width: selected ? 18 : 0,
									margin: const EdgeInsets.only(bottom: 6),
									decoration: BoxDecoration(
										color: scheme.primary,
										borderRadius: BorderRadius.circular(1),
									),
								),
								Icon(
									selected ? item.selectedIcon : item.icon,
									size: VgIcon.md + 2,
									color: color,
								),
							],
						),
						const SizedBox(height: 4),
						Text(
							item.label,
							maxLines: 1,
							overflow: TextOverflow.ellipsis,
							style: theme.textTheme.labelSmall?.copyWith(
								color: color,
								fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
							),
						),
					],
				),
			),
		);
	}
}

/// The compact header shown above a screen on a phone.
///
/// Carries the screen's name and, when one is open over the tabs, a back
/// arrow — so a secondary screen always shows both where it sits and how to
/// leave it.
class VgScreenHeader extends StatelessWidget {
	const VgScreenHeader({
		required this.title,
		this.onBack,
		this.trailing,
		super.key,
	});

	final String title;

	/// When set, a back arrow replaces the brand mark.
	final VoidCallback? onBack;

	final Widget? trailing;

	@override
	Widget build(BuildContext context) {
		final theme = Theme.of(context);
		return Padding(
			padding: const EdgeInsets.fromLTRB(
				VgSpace.lg,
				VgSpace.sm,
				VgSpace.lg,
				VgSpace.sm,
			),
			child: Row(
				children: [
					if (onBack != null)
						IconButton(
							onPressed: onBack,
							tooltip: 'Back',
							visualDensity: VisualDensity.compact,
							color: theme.colorScheme.onSurfaceVariant,
							icon: const Icon(Icons.arrow_back_rounded, size: VgIcon.md),
						)
					else
						const VgLogo(size: 26),
					const SizedBox(width: VgSpace.md),
					Expanded(
						child: Text(
							title,
							maxLines: 1,
							overflow: TextOverflow.ellipsis,
							style: theme.textTheme.titleLarge,
						),
					),
					?trailing,
				],
			),
		);
	}
}

/// The live connection summary shown in the sidebar footer.
///
/// Deliberately carries no elapsed timer. A ticking clock in the chrome would
/// rebuild the sidebar once a second for the whole session to report a figure
/// that is already on the dashboard — battery spent on a number nobody is
/// looking at.
class VgConnectionSummary extends StatelessWidget {
	const VgConnectionSummary({
		required this.tone,
		required this.label,
		this.detail,
		super.key,
	});

	/// The connection state this summary is reporting.
	final VgTone tone;
	final String label;
	final String? detail;

	@override
	Widget build(BuildContext context) {
		final theme = Theme.of(context);
		// Outlined, not filled: the sidebar behind it is already a raised
		// surface, so a card the same colour would be invisible — the footer
		// would read as text floating against the sidebar rather than as a
		// panel that can be lifted out of it.
		return VgSurface(
			outlined: true,
			padding: const EdgeInsets.all(VgSpace.md),
			child: Row(
				children: [
					VgStatusDot(tone: tone),
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
									style: theme.textTheme.titleSmall?.copyWith(
										color: theme.colorScheme.onSurface,
									),
								),
								if (detail != null)
									Text(
										detail!,
										maxLines: 1,
										overflow: TextOverflow.ellipsis,
										style: theme.textTheme.bodySmall,
									),
							],
						),
					),
				],
			),
		);
	}
}