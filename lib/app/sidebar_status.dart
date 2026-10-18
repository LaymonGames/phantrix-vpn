part of 'app_shell.dart';

/// The connection summary in the sidebar's footer.
///
/// Reads the controller rather than being handed a string, so the state on
/// every screen is the state the state machine is actually in — there is no
/// second copy to fall out of date. No timer runs here: the elapsed session
/// time is on the dashboard, and rebuilding the sidebar once a second for a
/// figure nobody is reading would spend battery to say nothing.
class _SidebarStatus extends StatelessWidget {
  const _SidebarStatus({required this.controller});

  final ConnectionController controller;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<ConnectionView>(
      initialData: controller.currentView,
      stream: controller.views,
      builder: (context, snapshot) {
        final view = snapshot.data ?? controller.currentView;
        final tone = toneOf(view.state);
        final l10n = L10n.of(context);
        final detail = switch (tone) {
          VgTone.connected =>
            view.selectedLabel ?? l10n.get('sidebarTunnelEstablished'),
          VgTone.working => l10n.get('sidebarNegotiating'),
          VgTone.failed =>
            view.canRetry ? l10n.get('sidebarTapToTryAgain') : null,
          VgTone.blocked => l10n.get('sidebarNeedsAttention'),
          VgTone.idle => l10n.get('sidebarNotProtected'),
        };
        return VgConnectionSummary(
          tone: tone,
          label: view.statusMessage,
          detail: detail,
        );
      },
    );
  }
}
