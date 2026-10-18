library;

import 'package:flutter/material.dart';
import 'package:phantrix_platform/phantrix_platform.dart';

import '../../l10n/strings.dart';
import '../../settings/settings_controller.dart';
import '../../theme/tokens.dart';
import '../components/status_style.dart';
import '../components/surfaces.dart';
import '../shell.dart';

part 'diag_status.dart';
part 'diag_row_card.dart';
part 'diag_state.dart';

/// The privacy diagnostics screen.
///
/// The rule this screen exists to enforce: nothing is reported as safe unless
/// it was actually measured. Every row shows one of:
///   * a measured value and a verdict;
///   * "Not tested", when the user has not run the check yet;
///   * "Not supported here", when the platform cannot measure it.
///
/// It never shows a green tick by default.
class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({
    required this.connection,
    required this.settings,
    super.key,
  });

  final ConnectionControllerLike connection;
  final SettingsController settings;

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

/// What the screen needs from the connection controller.
abstract class ConnectionControllerLike {
  Future<PlatformCapabilities> capabilities();
  bool get isConnected;

  /// The tunnel-verified exit address of the current or last session, or
  /// null when verification has not read one yet.
  String? get verifiedExitIp;

  /// Measures the public address the way the connect flow does: one HTTPS
  /// request to an address service. The trade-off is disclosed in
  /// PRIVACY.md, and it is the same one the leak check makes.
  Future<String?> readPublicIp();
}
