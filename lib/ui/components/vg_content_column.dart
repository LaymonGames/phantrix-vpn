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
