part of 'app_shell.dart';

class ShellWithNavigation extends StatefulWidget {
  const ShellWithNavigation({
    required this.scope,
    required this.reducedMotion,
    super.key,
  });

  final AppScope scope;
  final bool reducedMotion;

  @override
  State<ShellWithNavigation> createState() => _ShellWithNavigationState();
}

class _ShellWithNavigationState extends State<ShellWithNavigation> {
  final AppNavigation _navigation = AppNavigation();

  @override
  void dispose() {
    _navigation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final destinations = buildDestinations(
      widget.scope,
      _navigation,
      reducedMotion: widget.reducedMotion,
    );
    // Registered during build rather than in initState, because the list is
    // rebuilt whenever settings change and may then contain a new
    // destination.
    _navigation.register(destinations.map((d) => d.id).toList());
    return AppShell(
      destinations: destinations,
      navigation: _navigation,
      statusFooter: _SidebarStatus(controller: widget.scope.connection),
    );
  }
}

List<Destination> buildDestinations(
  AppScope scope,
  AppNavigation navigation, {
  bool reducedMotion = false,
}) => _destinations(scope, navigation, reducedMotion);
