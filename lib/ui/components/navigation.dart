/// The navigation surfaces, split by where they are used.
///
/// [nav_item.dart] holds the entry model, [sidebar.dart] the desktop rail
/// (with the connection summary in its footer), [tab_bar.dart] the phone bar
/// and [screen_header.dart] the compact phone header. [connection_summary.dart]
/// is the footer panel itself, shared by both surfaces.
///
/// They are re-exported here so a screen keeps importing a single path.
library;

export 'connection_summary.dart';
export 'nav_item.dart';
export 'screen_header.dart';
export 'sidebar.dart';
export 'tab_bar.dart';
