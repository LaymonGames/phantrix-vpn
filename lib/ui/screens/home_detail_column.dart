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
    required this.selectedCountryCode,
    required this.onChooseLocation,
  });

  final ConnectionView view;
  final L10n l10n;
  final String selectedCountryCode;
  final VoidCallback onChooseLocation;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        VgPanel(
          title: l10n.get('server'),
          icon: Icons.dns_rounded,
          uppercase: true,
          outlined: true,
          child: ServerPanel(
            view: view,
            selectedCountryCode: selectedCountryCode,
            onChooseLocation: onChooseLocation,
          ),
        ),
        // The public feed speaks OpenVPN. With no engine for it on this
        // platform, nothing on this screen could connect, and saying so
        // here beats letting the attempt fail. Unknown capabilities count
        // as unsupported, which is how the resolver treats the same
        // condition.
        if (!view.platform.openVpn) ...[
          const SizedBox(height: VgSpace.md),
          VgNote(
            title: l10n.get('publicRelayNoticeTitle'),
            message: l10n.get('publicFeedOpenVpnOnly'),
            icon: Icons.info_outline_rounded,
          ),
        ],
        if (view.isConnected ||
            view.isBusy ||
            view.session.startedAt != null) ...[
          const SizedBox(height: VgSpace.lg),
          SessionPanel(view: view),
        ],
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
