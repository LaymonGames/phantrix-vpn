part of 'home_screen.dart';

/// Everything the user reads: which server, what is known about the session,
/// and anything that needs their attention.
///
/// One widget so the phone and the desktop layout show the same set of blocks
/// in the same order, and so a change to one cannot silently drop a block from
/// the other.
class _DetailColumn extends StatelessWidget {
  const _DetailColumn({
    required this.view,
    required this.l10n,
    required this.settings,
    required this.selectedCountryCode,
    required this.onChooseLocation,
    required this.onOpenSettings,
  });

  final ConnectionView view;
  final L10n l10n;
  final AppSettings settings;
  final String selectedCountryCode;
  final VoidCallback onChooseLocation;
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Where the tunnel goes is shown, and changed, from the control
        // under the orb; a second server card repeated the same line.
        // The public feed speaks OpenVPN. With no engine for it on this
        // platform, nothing on this screen could connect, and saying so
        // here beats letting the attempt fail. Unknown capabilities count
        // as unsupported, which is how the resolver treats the same
        // condition.
        if (!view.platform.openVpn) ...[
          VgNote(
            title: l10n.get('publicRelayNoticeTitle'),
            message: l10n.get('publicFeedOpenVpnOnly'),
            icon: Icons.info_outline_rounded,
          ),
          const SizedBox(height: VgSpace.lg),
        ],
        if (view.isConnected ||
            view.isBusy ||
            view.session.startedAt != null) ...[
          SessionPanel(view: view),
          const SizedBox(height: VgSpace.lg),
        ],
        _ProtectionPanel(
          view: view,
          settings: settings,
          onOpenSettings: onOpenSettings,
        ),
        // The note about the attempt that just ended, and nothing else. The
        // platform's standing limitations are facts about the platform rather
        // than news about this attempt, and a paragraph of them under every
        // session is what made this screen read as documentation.
        if (view.lastFallback != null) ...[
          const SizedBox(height: VgSpace.lg),
          VgNote(message: view.lastFallback!),
        ],
      ],
    );
  }
}
