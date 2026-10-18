part of 'containers.dart';

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
  /// For a panel whose verdict *is* the point — a check that passed or
  /// failed — so the state is readable without reading a single word of it.
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
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
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
                          : Theme.of(context).textTheme.titleSmall?.copyWith(
                              color: Theme.of(context).colorScheme.onSurface,
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
