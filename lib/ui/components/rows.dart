import 'package:flutter/material.dart';

import '../../theme/tokens.dart';

/// A tappable row with an icon, a title, an optional subtitle and a trailing
/// control — the shape almost every navigable thing in the app takes.
///
/// Built on Material's [ListTile] rather than on a `Row` of boxes. That is
/// deliberate: a hand-rolled row has to reimplement the ripple, the focus
/// order, the semantic role and the keyboard activation, and a screen test
/// that has to search for a `ListTile` to tap a server row is a test that
/// documents the right abstraction. The app styles the tile; it does not
/// reinvent it.
class VgListRow extends StatelessWidget {
	const VgListRow({
		required this.title,
		this.subtitle,
		this.leading,
		this.trailing,
		this.onTap,
		this.selected = false,
		this.showDivider = false,
		this.contentPadding = const EdgeInsets.symmetric(vertical: VgSpace.xs),
		super.key,
	});

	final String title;
	final String? subtitle;
	final Widget? leading;
	final Widget? trailing;
	final VoidCallback? onTap;
	final bool selected;
	final bool showDivider;

	/// How the tile's own content is inset.
	///
	/// No horizontal inset by default, because these rows live inside a panel
	/// that already supplies one. A row that adds a second 16px puts its text
	/// out of line with the heading above it, which is the sort of drift that
	/// makes a settings screen look assembled rather than designed. Callers
	/// placing a row directly on the background pass their own.
	final EdgeInsetsGeometry contentPadding;

	@override
	Widget build(BuildContext context) {
		final theme = Theme.of(context);
		// A transparent `Material` above the surface's own decoration.
		// [ListTile] paints its selection tint and its ink splash on the
		// nearest `Material` ancestor; without one it reaches past this surface
		// to whatever is behind it, and the selection and the splash both
		// disappear under the card's fill. Transparency keeps the card's
		// background and its shadow, and hands the tile the surface it was
		// already painting on.
		return Material(
			type: MaterialType.transparency,
			child: Column(
				mainAxisSize: MainAxisSize.min,
				children: [
					ListTile(
						onTap: onTap,
						selected: selected,
						selectedTileColor: theme.colorScheme.primary.withValues(alpha: 0.07),
						// A hairline under the row rather than a gap: a settings
						// list read as a stack of separate cards loses the sense
						// that it is one list.
						contentPadding: contentPadding,
						minTileHeight: 56,
						leading: leading,
						title: Text(title),
						subtitle: subtitle == null ? null : Text(subtitle!),
						trailing:
							trailing ??
							(onTap == null ? null : const Icon(Icons.chevron_right_rounded)),
					),
					if (showDivider)
						Padding(
							padding: const EdgeInsetsDirectional.only(start: 56),
							child: Divider(color: theme.colorScheme.outline, height: 1),
						),
				],
			),
		);
	}
}

/// A settings row that switches.
///
/// The reason a control is disabled, when there is one, is rendered underneath
/// the row rather than in a tooltip: a control the platform cannot honour must
/// say so on the screen, not on hover.
class VgToggleRow extends StatelessWidget {
	const VgToggleRow({
		required this.title,
		required this.value,
		required this.onChanged,
		this.subtitle,
		this.enabled = true,
		this.disabledReason,
		super.key,
	});

	final String title;
	final String? subtitle;
	final bool value;
	final ValueChanged<bool> onChanged;
	final bool enabled;
	final String? disabledReason;

	@override
	Widget build(BuildContext context) {
		final theme = Theme.of(context);
		return Padding(
			padding: const EdgeInsets.symmetric(vertical: VgSpace.sm),
			child: Column(
				crossAxisAlignment: CrossAxisAlignment.start,
				mainAxisSize: MainAxisSize.min,
				children: [
					Row(
						children: [
							Expanded(
								child: Column(
									crossAxisAlignment: CrossAxisAlignment.start,
									mainAxisSize: MainAxisSize.min,
									children: [
										Text(
											title,
											style: theme.textTheme.bodyLarge?.copyWith(
												color: enabled
														? theme.colorScheme.onSurface
														: theme.colorScheme.onSurfaceVariant,
											),
										),
										if (subtitle != null) ...[
											const SizedBox(height: 2),
											Text(subtitle!, style: theme.textTheme.bodySmall),
										],
									],
								),
							),
							const SizedBox(width: VgSpace.lg),
							Switch(value: value, onChanged: enabled ? onChanged : null),
						],
					),
					if (!enabled && disabledReason != null)
						Padding(
							padding: const EdgeInsets.only(top: VgSpace.xs),
							child: Text(disabledReason!, style: theme.textTheme.bodySmall),
						),
				],
			),
		);
	}
}

/// A settings row offering a closed set of mutually exclusive options.
///
/// Segments rather than a dropdown and rather than a row of chips: the options
/// for every setting in this app are two or three short words, so showing them
/// all at once turns a two-tap decision into one, and removes the dialog that
/// used to sit between the user and a setting they came to change.
///
/// A [Wrap], never a [Row], so a long label or a large accessibility text scale
/// pushes the last segment onto a second line instead of clipping it. That is
/// the same reason the old quick-action row was a wrap.
class VgChoiceRow extends StatelessWidget {
	const VgChoiceRow({
		required this.title,
		required this.value,
		required this.options,
		this.note,
		this.icon,
		super.key,
	});

	final String title;
	final String value;

	/// Label to the action that selects it. Insertion-ordered, because the
	/// order the caller wrote is the order a reader expects.
	final Map<String, VoidCallback> options;

	/// Shown beneath the segments — an explanation, or the reason the platform
	/// cannot honour this setting.
	final String? note;

	final IconData? icon;

	@override
	Widget build(BuildContext context) {
		final theme = Theme.of(context);
		final scheme = theme.colorScheme;
		return Padding(
			padding: const EdgeInsets.symmetric(vertical: VgSpace.md),
			child: Column(
				crossAxisAlignment: CrossAxisAlignment.start,
				mainAxisSize: MainAxisSize.min,
				children: [
					Row(
						children: [
							if (icon != null) ...[
								Icon(icon, size: VgIcon.sm, color: scheme.onSurfaceVariant),
								const SizedBox(width: VgSpace.sm),
							],
							Expanded(
								child: Text(title, style: theme.textTheme.bodyLarge),
							),
						],
					),
					const SizedBox(height: VgSpace.sm),
					Wrap(
						spacing: VgSpace.sm,
						runSpacing: VgSpace.sm,
						children: [
							for (final entry in options.entries)
								VgSegment(
									label: entry.key,
									selected: entry.key == value,
									onTap: entry.value,
								),
						],
					),
					if (note != null) ...[
						const SizedBox(height: VgSpace.sm),
						Text(note!, style: theme.textTheme.bodySmall),
					],
				],
			),
		);
	}
}

/// One option in a closed set: a button that looks pressed while it is the
/// current choice.
///
/// Public because the servers screen's sort filters are exactly this control,
/// and giving them their own Material chip means a second selected-state
/// palette in the app — which is how a screen ends up with white text on a
/// pale fill, readable in neither theme.
class VgSegment extends StatelessWidget {
	const VgSegment({
		required this.label,
		required this.selected,
		required this.onTap,
		this.selectedIcon = Icons.check_rounded,
		super.key,
	});

	final String label;
	final bool selected;
	final VoidCallback onTap;

	/// Shown instead of the checkmark when this segment is selected. For a
	/// setting, the tick says "this is the value". A sort filter has no value
	/// to assert, so it passes null and is marked by its fill alone.
	final IconData? selectedIcon;

	@override
	Widget build(BuildContext context) {
		final theme = Theme.of(context);
		final scheme = theme.colorScheme;
		// The selected segment carries its own explicit colours. An ambient
		// chip theme paints every label in muted ink, which on a selected
		// segment's tint is roughly a 3:1 ratio — unreadable at exactly the
		// moment the user most needs to read it. `primary` reads on both the
		// dark and the light tint.
		final foreground = selected ? scheme.primary : scheme.onSurfaceVariant;
		return Semantics(
			button: true,
			selected: selected,
			child: InkWell(
				onTap: onTap,
				borderRadius: BorderRadius.circular(VgRadius.sm),
				child: AnimatedContainer(
					duration: VgMotion.fast,
					curve: VgMotion.standard,
					// No `alignment` here: an aligned container expands to fill
					// whatever width it is offered, which turns every option
					// into a full-width bar and makes a three-option setting
					// look like a stacked form.
					padding: const EdgeInsets.symmetric(
						horizontal: VgSpace.md,
						vertical: VgSpace.sm,
					),
					decoration: BoxDecoration(
						color: selected
								? scheme.primary.withValues(alpha: 0.14)
								: scheme.surfaceContainerHigh,
						borderRadius: BorderRadius.circular(VgRadius.sm),
						border: Border.all(
							color: selected ? scheme.primary : scheme.outline,
						),
					),
					child: Row(
						mainAxisSize: MainAxisSize.min,
						children: [
							if (selected && selectedIcon != null) ...[
								Icon(
									selectedIcon!,
									size: VgIcon.sm,
									color: foreground,
								),
								const SizedBox(width: 6),
							],
							// Flexible, so a long option label wraps onto a second
							// line inside its own segment rather than overflowing it.
							// A settings option that is truncated is a setting the
							// user cannot read the value of — and on a phone the
							// longest of these ("VPN server DNS") is wider than the
							// space a segment gets.
							Flexible(
								child: Text(
									label,
									maxLines: 2,
									overflow: TextOverflow.ellipsis,
									style: theme.textTheme.labelMedium?.copyWith(
										color: foreground,
										fontWeight: selected
												? FontWeight.w700
												: FontWeight.w600,
									),
								),
							),
						],
					),
				),
			),
		);
	}
}