part of 'shell.dart';

/// The shell's view of navigation.
///
/// An interface rather than the concrete class so that the shell can be
/// exercised in a widget test with a simple stub. It extends [Listenable]
/// because the shell rebuilds from it: the selected destination can change
/// without this widget being rebuilt by its parent, and a sidebar whose
/// highlight had drifted from its content would be worse than no sidebar.
abstract class AppNavigationLike extends Listenable {
  int get index;
  String? get currentId;

  /// Selects a destination by index.
  ///
  /// A callback rather than a method taking the destination, because that is
  /// exactly the signature the navigation surfaces want.
  void Function(int) get select;
}

class Destination {
  const Destination({
    required this.id,
    required this.label,
    required this.icon,
    required this.selectedIcon,
    required this.builder,
    this.parentId,
  });

  final String id;
  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final WidgetBuilder builder;

  /// The primary destination this one belongs *under*, or null when this *is*
  /// a primary destination.
  ///
  /// The app is a three-tab product — Home, Servers, Settings. A secondary
  /// destination (diagnostics, privacy, licenses) is opened over those tabs
  /// rather than crowding them: it never
  /// appears as its own tab, but it highlights and can return to its
  /// [parentId], so a user always sees where it sits and how to leave.
  /// Keeping the bar at three is what stops the labels ellipsising at a large
  /// accessibility text scale for exactly the users who enlarged the text.
  final String? parentId;

  bool get isPrimary => parentId == null;
}
