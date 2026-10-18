/// The ways a server can be picked.
///
/// Kept separate from a selection reason because the mode is what the user
/// asked for and the reason is what happened.
enum SelectionMode {
  fastest,
  nearest,
  random,
  recommended,
  healthiest,
  favorite,
  recent,
  manual,
  specificServer,
}

extension SelectionModeLabel on SelectionMode {
  String get label => switch (this) {
    SelectionMode.fastest => 'Fastest measured',
    SelectionMode.nearest => 'Nearest by latency',
    SelectionMode.random => 'Random among eligible servers',
    SelectionMode.recommended => 'Recommended for reliability',
    SelectionMode.healthiest => 'Best recent health',
    SelectionMode.favorite => 'Your favorite',
    SelectionMode.recent => 'Recently used',
    SelectionMode.manual => 'Selected by you',
    SelectionMode.specificServer => 'A specific server you chose',
  };
}
