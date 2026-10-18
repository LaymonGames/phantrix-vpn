import 'package:flutter/material.dart';

import 'package:phantrix_platform/phantrix_platform.dart';

import '../../../settings/settings_controller.dart';
import '../../../theme/tokens.dart';
import '../../components/surfaces.dart';
import '../../shell.dart';
import 'about_panel.dart';
import 'advanced_panel.dart';
import 'appearance_panel.dart';
import 'clear_data_surface.dart';
import 'connection_panel.dart';
import 'privacy_panel.dart';

/// The settings screen.
///
/// A control the platform cannot honour is shown disabled with the reason
/// beside it, rather than hidden or silently ignored.
///
/// Grouped into labelled panels rather than one long list of cards: the
/// screen used to render each setting as its own `Card`, which made a list of
/// eighteen settings look like eighteen unrelated things. One panel per
/// concern — Connection, Privacy, Appearance, Advanced, About — reads as the
/// handful of decisions the user is actually making.
///
/// Each panel is its own widget so that a change to one cannot reach into
/// another's state, and so this file stays the list rather than the contents.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    required this.settings,
    required this.platform,
    required this.onOpenDiagnostics,
    required this.onClearLocalData,
    required this.onOpenSystemVpnSettings,
    required this.systemLockdownActive,
    required this.onStartOnBootChanged,
    super.key,
  });

  final SettingsController settings;
  final PlatformCapabilities platform;

  /// Opens the diagnostics screen.
  ///
  /// Diagnostics and Privacy are not in the phone bottom bar, because six
  /// labels do not survive a large text scale. They are linked from here
  /// instead, which is the screen a user is already in when they want them —
  /// so removing them from the bar costs one tap rather than the feature.
  final VoidCallback onOpenDiagnostics;

  /// Opens the operating system's own VPN settings.
  ///
  /// Used by the system-lockdown row, which is the one control on this
  /// screen that the app cannot honour itself: enabling lockdown happens in
  /// the system settings, so the row links there instead of pretending a
  /// switch here could do it.
  final VoidCallback onOpenSystemVpnSettings;

  /// Reads whether the OS itself is currently blocking traffic outside a
  /// VPN, live rather than cached.
  final Future<bool> Function() systemLockdownActive;

  /// Asks the platform to start (or to stop starting) the app at sign-in,
  /// answering whether the machine accepted the choice.
  final Future<bool> Function(bool) onStartOnBootChanged;

  /// Resets every local preference, keeping the onboarding flags.
  final VoidCallback onClearLocalData;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return AnimatedBuilder(
      animation: settings,
      builder: (context, _) {
        // Capped like every other screen. A settings list stretched
        // across a 1440px window puts a toggle switch a metre away from
        // the label that explains it.
        return VgContentColumn(
          child: ListView(
            padding: const EdgeInsets.only(
              top: VgSpace.sm,
              bottom: VgSpace.xxl,
            ),
            children: [
              ConnectionPanel(
                settings: settings,
                platform: platform,
                onOpenSystemVpnSettings: onOpenSystemVpnSettings,
                systemLockdownActive: systemLockdownActive,
                onStartOnBootChanged: onStartOnBootChanged,
              ),
              const SizedBox(height: VgSpace.lg),
              PrivacyPanel(settings: settings),
              const SizedBox(height: VgSpace.lg),
              AppearancePanel(settings: settings),
              const SizedBox(height: VgSpace.lg),
              // The screens that are not in the phone bottom bar. Linked
              // from here so that trimming the bar to three labels does
              // not make them unreachable on a phone.
              AdvancedPanel(
                onOpenDiagnostics: onOpenDiagnostics,
              ),
              const SizedBox(height: VgSpace.lg),
              ClearDataSurface(onClear: onClearLocalData),
              const SizedBox(height: VgSpace.md),
              Text(
                l10n.get('aboutDisclaimer'),
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: VgSpace.lg),
              AboutPanel(),
            ],
          ),
        );
      },
    );
  }
}
