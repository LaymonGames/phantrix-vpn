import 'package:flutter/material.dart';

import '../../theme/tokens.dart';

/// A raised surface.
///
/// The single card primitive in the app. Screens compose from this rather than
/// using [Card] directly so that the elevation, radius and padding stay
/// identical everywhere — which is what makes a screen feel designed rather
/// than assembled.
class VgSurface extends StatelessWidget {
	const VgSurface({
		required this.child,
		this.padding = const EdgeInsets.all(VgSpace.lg),
		this.onTap,
		this.accent,
		this.elevated = false,
		this.outlined = false,
		this.clip = true,
		super.key,
	});

	final Widget child;
	final EdgeInsetsGeometry padding;

	/// When set, the surface becomes a button.
	final VoidCallback? onTap;

	/// A hairline in this colour along the leading edge, used to mark the
	/// selected item in a list.
	final Color? accent;

	final bool elevated;

	/// Draws a hairline around the surface.
	///
	/// Off by default, because depth comes from layered surfaces rather than
	/// outlines. It is on for surfaces that sit *inside* another surface —
	/// an inset well — where there is no tonal step to separate them.
	final bool outlined;

	/// Whether to clip the children to [radius].
	///
	/// Off for a surface whose child paints its own edge decoration, such as
	/// an accent bar that must not be rounded away.
	final bool clip;

	static BorderRadius radiusFor(double r) => BorderRadius.circular(r);

	@override
	Widget build(BuildContext context) {
		final theme = Theme.of(context);
		final isDark = theme.brightness == Brightness.dark;
		final radius = BorderRadius.circular(VgRadius.lg);

		final content = Padding(padding: padding, child: child);

		Widget surface = DecoratedBox(
			decoration: BoxDecoration(
				color: theme.colorScheme.surfaceContainerLow,
				borderRadius: radius,
				border: outlined
						? Border.all(color: theme.colorScheme.outlineVariant)
						: null,
				boxShadow: elevated
						? VgShadow.forCard(isDark ? Colors.black : const Color(0xFF1E3A2B))
						: null,
			),
			child: content,
		);

		// The accent is a separate inset rather than a one-sided `Border`:
		// a `Border` with different colours per side has no valid borderRadius,
		// and Flutter refuses to paint one. Clipping to the radius and drawing
		// the strip inside gives the same result and is legal.
		if (accent != null) {
			surface = ClipRRect(
				borderRadius: radius,
				child: Stack(
					children: [
						surface,
						PositionedDirectional(
							start: 0,
							top: 0,
							bottom: 0,
							width: 3,
							child: ColoredBox(color: accent!),
						),
					],
				),
			);
		}

		if (onTap == null) {
			return surface;
		}
		return _Pressable(onTap: onTap!, borderRadius: radius, child: surface);
	}
}

/// A surface with a heading, the workhorse container of the redesign.
///
/// Almost every block of information in the app is "a thing with a name, and
/// then the thing itself". Making that a primitive is what stops each screen
/// from inventing its own heading spacing, and what makes a screen read as a
/// set of named panels rather than a stack of boxes.
class VgPanel extends StatelessWidget {
	const VgPanel({
		required this.child,
		this.title,
		this.icon,
		this.trailing,
		this.padding = const EdgeInsets.all(VgSpace.lg),
		this.elevated = false,
		this.outlined = false,
		this.accent,
		this.expand = false,
		this.uppercase = false,
		super.key,
	});

	final Widget child;

	/// The panel's name. When null the panel is untitled, which is correct for
	/// a panel that is obviously what it is — the connect control, for
	/// instance.
	final String? title;

	/// A small icon shown beside the title.
	final IconData? icon;

	/// A control on the right of the heading, such as a refresh button.
	final Widget? trailing;

	final EdgeInsetsGeometry padding;
	final bool elevated;
	final bool outlined;

	/// A hairline on the leading edge in this colour.
	///
	/// For a panel whose verdict *is* the point — a configuration that is
	/// validated or is not, a check that passed or failed — so the state is
	/// readable without reading a single word of it.
	final Color? accent;

	/// Whether this panel's content fills the height it is given.
	///
	/// False by default so a panel hugs its content inside a scrolling column.
	/// True for the one panel in a layout that should absorb the leftover
	/// space rather than leaving a void beneath it.
	final bool expand;

	/// Renders the title as a small uppercase label rather than a heading.
	///
	/// The two are different jobs and look different on purpose. An uppercase
	/// micro-label says "there is a group of things below"; a sentence-case
	/// heading says "this specific thing is what you are reading". Panels that
	/// name a category — Server, This session — take the label; panels that
	/// name a piece of prose take the heading.
	final bool uppercase;

	@override
	Widget build(BuildContext context) {
		final hasHeader = title != null || trailing != null;
		return VgSurface(
			elevated: elevated,
			outlined: outlined,
			accent: accent,
			padding: EdgeInsets.zero,
			child: Column(
				mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
				crossAxisAlignment: CrossAxisAlignment.stretch,
				children: [
					if (hasHeader)
						Padding(
							padding: const EdgeInsets.fromLTRB(
								VgSpace.lg,
								VgSpace.lg,
								VgSpace.md,
								VgSpace.xs,
							),
							child: Row(
								children: [
									if (icon != null) ...[
										Icon(
											icon,
											size: VgIcon.sm,
											color: Theme.of(context)
												.colorScheme
												.onSurfaceVariant,
										),
										const SizedBox(width: VgSpace.sm),
									],
									Expanded(
										child: Text(
											uppercase ? (title ?? '').toUpperCase() : (title ?? ''),
											maxLines: 2,
											overflow: TextOverflow.ellipsis,
											style: uppercase
													? Theme.of(context).textTheme.labelSmall
															?.copyWith(letterSpacing: 0.9)
													: Theme.of(context).textTheme.titleSmall
															?.copyWith(
																color: Theme.of(context)
																	.colorScheme
																	.onSurface,
															),
										),
									),
									?trailing,
								],
							),
						),
					Padding(
						// A titled panel's body is inset by the heading's own
						// left edge so the two align; an untitled panel takes
						// its own padding.
						padding: hasHeader
								? const EdgeInsets.fromLTRB(
										VgSpace.lg,
										VgSpace.md,
										VgSpace.lg,
										VgSpace.lg,
									)
								: padding,
						child: child,
					),
				],
			),
		);
	}
}

/// Adds a press-scale to a tappable surface.
///
/// The scale is small — 1.5% — because a large one makes a list of servers feel
/// like a toy, and because a surface that shrinks visibly reflows the text
/// inside it.
class _Pressable extends StatefulWidget {
	const _Pressable({
		required this.child,
		required this.onTap,
		required this.borderRadius,
	});

	final Widget child;
	final VoidCallback onTap;
	final BorderRadius borderRadius;

	@override
	State<_Pressable> createState() => _PressableState();
}

class _PressableState extends State<_Pressable> {
	bool _pressed = false;

	@override
	Widget build(BuildContext context) {
		final theme = Theme.of(context);
		return Semantics(
			button: true,
			child: MouseRegion(
				cursor: SystemMouseCursors.click,
				child: GestureDetector(
					onTapDown: (_) => setState(() => _pressed = true),
					onTapUp: (_) => setState(() => _pressed = false),
					onTapCancel: () => setState(() => _pressed = false),
					onTap: widget.onTap,
					child: AnimatedScale(
						scale: _pressed ? 0.985 : 1,
						duration: VgMotion.fast,
						curve: VgMotion.standard,
						child: DecoratedBox(
							decoration: ShapeDecoration(
								color: _pressed
										? theme.colorScheme.onSurface.withValues(alpha: 0.04)
										: const Color(0x00000000),
								shape: RoundedRectangleBorder(
									borderRadius: widget.borderRadius,
								),
							),
							child: widget.child,
						),
					),
				),
			),
		);
	}
}

/// A small uppercase heading that separates sections.
class VgSectionHeader extends StatelessWidget {
	const VgSectionHeader(this.title, {this.trailing, this.dense = false, super.key});

	final String title;
	final Widget? trailing;

	/// Removes the space above the heading.
	///
	/// Used inside a panel, where the heading is bounded by the panel rather
	/// than floating between two sections.
	final bool dense;

	@override
	Widget build(BuildContext context) {
		final theme = Theme.of(context);
		return Padding(
			// Generous above and tight below: the space belongs to the heading
			// that introduces the section, not to the section above it.
			padding: EdgeInsets.only(
				bottom: dense ? VgSpace.xs : VgSpace.md,
				top: dense ? 0 : VgSpace.xl,
			),
			child: Row(
				children: [
					Expanded(
						child: Text(
							title.toUpperCase(),
							style: theme.textTheme.labelSmall?.copyWith(
								letterSpacing: 0.9,
								color: theme.colorScheme.onSurfaceVariant,
							),
						),
					),
					if (trailing != null) ...[trailing!],
				],
			),
		);
	}
}

/// A labelled value, the workhorse of every details panel.
///
/// The value wraps and the label does not, and both flex, because a fixed-width
/// column of labels overflows the moment the user enlarges the text — which is
/// exactly what an accessibility setting is for.
class VgInfoRow extends StatelessWidget {
	const VgInfoRow({
		required this.label,
		required this.value,
		this.icon,
		this.valueStyle,
		this.monospace = false,
		super.key,
	});

	final String label;
	final String value;
	final IconData? icon;
	final TextStyle? valueStyle;

	/// Renders the value in a fixed-pitch face, which is right for an address
	/// or a key and wrong for a sentence.
	final bool monospace;

	@override
	Widget build(BuildContext context) {
		final theme = Theme.of(context);
		final muted = theme.textTheme.bodyMedium;
		return Padding(
			padding: const EdgeInsets.symmetric(vertical: VgSpace.sm),
			child: Row(
				crossAxisAlignment: CrossAxisAlignment.start,
				children: [
					if (icon != null) ...[
						Icon(icon, size: VgIcon.sm, color: theme.colorScheme.onSurfaceVariant),
						const SizedBox(width: VgSpace.md),
					],
					Expanded(
						flex: 4,
						child: Text(label, style: muted),
					),
					const SizedBox(width: VgSpace.md),
					Expanded(
						flex: 5,
						child: Text(
							value,
							textAlign: TextAlign.end,
							style:
									valueStyle ??
									theme.textTheme.titleMedium?.copyWith(
										fontFamily: monospace ? 'monospace' : null,
										fontFeatures: monospace ? null : VgType.tabular,
									),
						),
					),
				],
			),
		);
	}
}

/// A compact metric.
///
/// Used in a row of three or four, never alone: a single number floating on its
/// own reads as important, and these numbers are not.
class VgStat extends StatelessWidget {
	const VgStat({
		required this.label,
		required this.value,
		this.icon,
		this.tone,
		super.key,
	});

	final String label;
	final String value;
	final IconData? icon;

	/// Overrides the default emphasis. Used to make a live figure stand out.
	final Color? tone;

	@override
	Widget build(BuildContext context) {
		final theme = Theme.of(context);
		return Container(
			padding: const EdgeInsets.symmetric(
				horizontal: VgSpace.md,
				vertical: VgSpace.md,
			),
			decoration: BoxDecoration(
				// Inset a step below the panel it sits in, so a group of three
				// reads as one object with three figures rather than three
				// cards competing with the card around them.
				color: theme.colorScheme.surfaceContainer,
				borderRadius: BorderRadius.circular(VgRadius.md),
			),
			child: Column(
				crossAxisAlignment: CrossAxisAlignment.start,
				mainAxisSize: MainAxisSize.min,
				children: [
					Row(
						children: [
							if (icon != null) ...[
								Icon(
									icon,
									size: VgIcon.sm - 3,
									color: theme.colorScheme.onSurfaceVariant,
								),
								const SizedBox(width: VgSpace.xs),
							],
							Expanded(
								child: Text(
									label,
									maxLines: 1,
									overflow: TextOverflow.ellipsis,
									style: theme.textTheme.labelSmall,
								),
							),
						],
					),
					const SizedBox(height: VgSpace.xs),
					FittedBox(
						// The number must never wrap onto a second line: a stat
						// that is two lines tall breaks the row it sits in.
						fit: BoxFit.scaleDown,
						alignment: Alignment.centerLeft,
						child: Text(
							value,
							maxLines: 1,
							style: theme.textTheme.titleMedium?.copyWith(
								color: tone ?? theme.colorScheme.onSurface,
								fontFeatures: VgType.tabular,
								fontWeight: FontWeight.w700,
							),
						),
					),
				],
			),
		);
	}
}

/// A short, coloured state chip.
///
/// Distinct from a badge that reports a count: this one carries *meaning*, so
/// it always has a label and never a bare number without context.
class VgChip extends StatelessWidget {
	const VgChip({
		required this.label,
		required this.color,
		this.icon,
		this.filled = true,
		super.key,
	});

	final String label;
	final Color color;
	final IconData? icon;
	final bool filled;

	@override
	Widget build(BuildContext context) {
		final theme = Theme.of(context);
		return Container(
			padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
			decoration: BoxDecoration(
				color: color.withValues(alpha: filled ? 0.14 : 0.0),
				borderRadius: BorderRadius.circular(VgRadius.pill),
				border: Border.all(color: color.withValues(alpha: filled ? 0.0 : 0.4)),
			),
			child: Row(
				mainAxisSize: MainAxisSize.min,
				children: [
					if (icon != null) ...[
						Icon(icon, size: 13, color: color),
						const SizedBox(width: 6),
					],
					Text(
						label,
						style: theme.textTheme.labelMedium?.copyWith(color: color),
					),
				],
			),
		);
	}
}

/// An explanatory note.
///
/// Used for the things a user needs told — a platform limitation, a repair
/// that will be applied, a caution about what a public relay can see. Its tone
/// is neutral by default because a note is usually information rather than a
/// problem, and colouring everything as a warning trains people to ignore
/// colour.
class VgNote extends StatelessWidget {
	const VgNote({
		required this.message,
		this.icon = Icons.info_outline_rounded,
		this.color,
		this.title,
		this.action,
		super.key,
	});

	final String message;
	final IconData icon;
	final Color? color;
	final String? title;
	final Widget? action;

	@override
	Widget build(BuildContext context) {
		final theme = Theme.of(context);
		final tone = color ?? theme.colorScheme.onSurfaceVariant;
		return Container(
			padding: const EdgeInsets.all(VgSpace.md),
			decoration: BoxDecoration(
				color: tone.withValues(alpha: 0.08),
				borderRadius: BorderRadius.circular(VgRadius.md),
				// A single hairline in the same hue at low alpha. The tint
				// alone is too soft to find with a glance on a busy screen,
				// and a full-strength border would shout.
				border: Border.all(color: tone.withValues(alpha: 0.22)),
			),
			child: Row(
				crossAxisAlignment: CrossAxisAlignment.start,
				children: [
					Icon(icon, size: VgIcon.sm, color: tone),
					const SizedBox(width: VgSpace.md),
					Expanded(
						child: Column(
							crossAxisAlignment: CrossAxisAlignment.start,
							children: [
								if (title != null) ...[
									Text(title!, style: theme.textTheme.titleSmall),
									const SizedBox(height: 2),
								],
								Text(message, style: theme.textTheme.bodySmall),
								if (action != null) ...[
									const SizedBox(height: VgSpace.sm),
									action!,
								],
							],
						),
					),
				],
			),
		);
	}
}

/// An error with something to do about it.
///
/// Every failure in this app has a next step, because a message that only says
/// something went wrong leaves the user with no action. When there is genuinely
/// no action available, the caller says so in the message rather than showing
/// a button that does nothing.
class VgErrorCard extends StatelessWidget {
	const VgErrorCard({
		required this.message,
		this.code,
		this.actionLabel,
		this.onAction,
		super.key,
	});

	final String message;
	final String? code;
	final String? actionLabel;
	final VoidCallback? onAction;

	@override
	Widget build(BuildContext context) {
		final theme = Theme.of(context);
		return VgSurface(
			accent: theme.colorScheme.error,
			padding: const EdgeInsets.all(VgSpace.lg),
			child: Column(
				mainAxisSize: MainAxisSize.min,
				crossAxisAlignment: CrossAxisAlignment.start,
				children: [
					Row(
						crossAxisAlignment: CrossAxisAlignment.start,
						children: [
							Icon(
								Icons.error_outline_rounded,
								size: VgIcon.md,
								color: theme.colorScheme.error,
							),
							const SizedBox(width: VgSpace.md),
							Expanded(
								child: Text(
									message,
									style: theme.textTheme.bodyLarge?.copyWith(
										color: theme.colorScheme.onSurface,
									),
								),
							),
						],
					),
					if (actionLabel != null && onAction != null) ...[
						const SizedBox(height: VgSpace.md),
						Align(
							alignment: Alignment.centerLeft,
							// Wrap the button so a long label wraps instead of
							// overflowing: the button's own text is user-facing
							// copy that changes with the locale.
							child: ConstrainedBox(
								constraints: const BoxConstraints(maxWidth: 220),
								child: FilledButton.tonal(
									onPressed: onAction,
									child: Text(
										actionLabel!,
										maxLines: 1,
										overflow: TextOverflow.ellipsis,
									),
								),
							),
						),
					],
					if (code != null) ...[
						const SizedBox(height: VgSpace.sm),
						Text(
							code!,
							style: theme.textTheme.labelSmall?.copyWith(
								fontFamily: 'monospace',
								color: theme.colorScheme.onSurfaceVariant,
							),
						),
					],
				],
			),
		);
	}
}

/// An empty state: an explanation of why there is nothing here, and the one
/// action that would fix it.
///
/// Shown instead of a blank list. A list that is simply empty reads as a bug;
/// an empty state that says what is missing and what to do about it reads as
/// the app knowing what it is doing.
class VgEmptyState extends StatelessWidget {
	const VgEmptyState({
		required this.icon,
		required this.title,
		required this.message,
		this.actionLabel,
		this.onAction,
		this.compact = false,
		super.key,
	});

	final IconData icon;
	final String title;
	final String message;
	final String? actionLabel;
	final VoidCallback? onAction;

	/// Drops the oversized icon and the action button.
	///
	/// For an empty state that appears *inside* a panel that already offers
	/// the same action one screen-reader-height above — two full empty states
	/// on one screen is one too many.
	final bool compact;

	@override
	Widget build(BuildContext context) {
		final theme = Theme.of(context);
		return Center(
			child: ConstrainedBox(
				constraints: const BoxConstraints(maxWidth: 380),
				child: Padding(
					padding: const EdgeInsets.all(VgSpace.xl),
					child: Column(
						mainAxisSize: MainAxisSize.min,
						children: [
							if (!compact) ...[
								Container(
									width: 64,
									height: 64,
									decoration: BoxDecoration(
										color: theme.colorScheme.onSurface.withValues(
											alpha: 0.06,
										),
										shape: BoxShape.circle,
									),
									child: Icon(
										icon,
										size: VgIcon.lg,
										color: theme.colorScheme.onSurfaceVariant,
									),
								),
								const SizedBox(height: VgSpace.lg),
							],
							Text(
								title,
								textAlign: TextAlign.center,
								style: theme.textTheme.titleLarge,
							),
							const SizedBox(height: VgSpace.sm),
							Text(
								message,
								textAlign: TextAlign.center,
								style: theme.textTheme.bodyMedium,
							),
							if (!compact &&
								actionLabel != null &&
								onAction != null) ...[
								const SizedBox(height: VgSpace.xl),
								FilledButton(onPressed: onAction, child: Text(actionLabel!)),
							],
						],
					),
				),
			),
		);
	}
}

/// Constrains content to a readable measure and centres it.
///
/// A 4K monitor makes an unconstrained column of text unreadable, and this is
/// what stops the app looking stretched on one. Pass [wide] for a dashboard,
/// whose columns are not a measure of prose and are allowed to be wider.
class VgContentColumn extends StatelessWidget {
	const VgContentColumn({
		required this.child,
		this.maxWidth = VgSpace.maxContentWidth,
		this.wide = false,
		this.padding,
		super.key,
	});

	final Widget child;
	final double maxWidth;

	/// Uses the dashboard measure rather than the reading measure.
	final bool wide;

	final EdgeInsetsGeometry? padding;

	@override
	Widget build(BuildContext context) {
		final width = MediaQuery.sizeOf(context).width;
		return Align(
			alignment: Alignment.topCenter,
			child: ConstrainedBox(
				constraints: BoxConstraints(
					maxWidth: wide ? VgSpace.maxDashboardWidth : maxWidth,
				),
				child: Padding(
					padding: padding ?? EdgeInsets.symmetric(horizontal: VgSpace.gutter(width)),
					child: child,
				),
			),
		);
	}
}

/// A shimmerless busy indicator with a label.
///
/// A bare spinner tells the user something is happening and nothing else.
/// Naming the operation is the difference between "the app is thinking" and
/// "the app is talking to the server directory", and it costs one line.
class VgBusy extends StatelessWidget {
	const VgBusy(this.message, {this.compact = false, super.key});

	final String message;

	/// A spinner and the label on one line, for a button or a panel header.
	final bool compact;

	@override
	Widget build(BuildContext context) {
		final theme = Theme.of(context);
		if (compact) {
			return Row(
				mainAxisSize: MainAxisSize.min,
				children: [
					const SizedBox(
						width: VgIcon.sm,
						height: VgIcon.sm,
						child: CircularProgressIndicator(strokeWidth: 2),
					),
					const SizedBox(width: VgSpace.sm),
					Text(message, style: theme.textTheme.labelMedium),
				],
			);
		}
		return Center(
			child: Column(
				mainAxisSize: MainAxisSize.min,
				children: [
					const SizedBox(
						width: 26,
						height: 26,
						child: CircularProgressIndicator(strokeWidth: 2.5),
					),
					const SizedBox(height: VgSpace.md),
					Text(message, style: theme.textTheme.bodyMedium),
				],
			),
		);
	}
}