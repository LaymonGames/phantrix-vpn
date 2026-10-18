part of 'tokens.dart';

class VgShadow {
  VgShadow._();

  static List<BoxShadow> forCard(Color tint) => [
    BoxShadow(
      color: tint.withValues(alpha: 0.5),
      blurRadius: 24,
      offset: const Offset(0, 8),
      spreadRadius: -8,
    ),
  ];

  static List<BoxShadow> forLifted(Color tint, {double strength = 0.62}) => [
    BoxShadow(
      color: tint.withValues(alpha: strength),
      blurRadius: 48,
      offset: const Offset(0, 20),
      spreadRadius: -12,
    ),
  ];

  /// The shadow under the desktop sidebar.
  ///
  /// Separate from [forCard] because a sidebar is full-height: it needs to
  /// separate from the content beside it rather than lift off the floor.
  static List<BoxShadow> forSidebar(Color tint) => [
    BoxShadow(
      color: tint.withValues(alpha: 0.55),
      blurRadius: 32,
      offset: const Offset(8, 0),
      spreadRadius: -12,
    ),
  ];
}
