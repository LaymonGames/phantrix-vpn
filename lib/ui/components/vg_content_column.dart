part of 'containers.dart';

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
          padding:
              padding ??
              EdgeInsets.symmetric(horizontal: VgSpace.gutter(width)),
          child: child,
        ),
      ),
    );
  }
}

/// The scrolling form of [VgContentColumn].
///
/// [VgContentColumn] narrows its child, so a scroll view placed inside it
/// only receives pointer events over the centred column: a mouse wheel over
/// the empty margins of a wide desktop window did nothing. This keeps the
/// scroll view at the full width of the page and moves the measure into its
/// padding instead, so the content sits exactly where [VgContentColumn]
/// would put it while the wheel works anywhere on the page.
///
/// [builder] receives the horizontal insets to give the scroll view's
/// `padding`; add the vertical padding with `copyWith`.
class VgScrollColumn extends StatelessWidget {
  const VgScrollColumn({
    required this.builder,
    this.maxWidth = VgSpace.maxContentWidth,
    this.wide = false,
    super.key,
  });

  final Widget Function(BuildContext context, EdgeInsets insets) builder;
  final double maxWidth;

  /// Uses the dashboard measure rather than the reading measure.
  final bool wide;

  /// The horizontal insets that centre a column of at most [maxWidth] in
  /// [available], gutter included — the same box [VgContentColumn] draws.
  static EdgeInsets insetsFor({
    required double available,
    required double viewportWidth,
    required double maxWidth,
  }) {
    final column = available < maxWidth ? available : maxWidth;
    final margin = (available - column) / 2;
    return EdgeInsets.symmetric(
      horizontal: margin + VgSpace.gutter(viewportWidth),
    );
  }

  @override
  Widget build(BuildContext context) {
    final viewportWidth = MediaQuery.sizeOf(context).width;
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : viewportWidth;
        return builder(
          context,
          insetsFor(
            available: available,
            viewportWidth: viewportWidth,
            maxWidth: wide ? VgSpace.maxDashboardWidth : maxWidth,
          ),
        );
      },
    );
  }
}
