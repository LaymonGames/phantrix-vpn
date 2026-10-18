import 'package:flutter/foundation.dart';

import '../ui/shell.dart';

/// Which screen the shell is showing.
///
/// Held as a [ChangeNotifier] above the shell rather than as state inside it,
/// because screens need to be able to send the user somewhere: the home
/// screen's "Choose a location" has to move the shell, and a screen that
/// cannot do that is how a button ends up wired to an empty callback.
class AppNavigation extends ChangeNotifier implements AppNavigationLike {
  int _index = 0;

  @override
  int get index => _index;

  /// The current destination's id.
  @override
  String? get currentId => _ids.isEmpty ? null : _ids[_index];

  /// Registers the destination ids in order.
  ///
  /// Called by the shell once, when it builds. Kept separate from [go] so
  /// that a request naming an unknown id is ignored rather than landing the
  /// user on a screen that does not exist.
  void register(List<String> ids) => _ids = ids;

  /// Moves to the destination with [id], if there is one.
  bool go(String id) {
    final target = _ids.indexOf(id);
    if (target < 0 || target == index) {
      return false;
    }
    select(target);
    return true;
  }

  @override
  void Function(int) get select => _select;

  void _select(int value) {
    if (value == _index || value < 0 || value >= _ids.length) {
      return;
    }
    _index = value;
    notifyListeners();
  }

  List<String> _ids = const [];
}
