import 'package:flutter/material.dart';

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
