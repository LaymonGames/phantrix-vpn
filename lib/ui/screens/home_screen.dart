library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../theme/tokens.dart';
import '../../vpn/connection_controller.dart';
import '../../vpn/connection_view.dart';
import '../components/surfaces.dart';
import 'home_details.dart';
import 'home_hero.dart';

part 'home_screen_state.dart';
part 'home_detail_column.dart';

/// The connection screen.
///
/// Ordered by what the user needs first: the state of the tunnel, then which
/// server it goes to, then what is actually known about the session, then
/// anything that needs their attention. Everything else is a link away.
///
/// ## Two layouts, one content
///
/// On a phone this is a single scrolling column: the control, then the server,
/// then the facts. On a desktop window the same content becomes two columns —
/// the control holds the left, everything the user reads holds the right — so
/// the window's extra width buys something other than a longer scroll. The
/// content and its order are identical; only the arrangement changes.
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    required this.connection,
    required this.reducedMotion,
    this.selectedCountryCode = 'AUTO',
    required this.onQuickConnect,
    required this.onChooseLocation,
    super.key,
  });

  final ConnectionController connection;
  final bool reducedMotion;
  final String selectedCountryCode;
  final Future<void> Function() onQuickConnect;
  final VoidCallback onChooseLocation;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}
