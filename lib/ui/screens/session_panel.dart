part of 'home_details.dart';

class SessionPanel extends StatelessWidget {
  const SessionPanel({required this.view, super.key});

  final ConnectionView view;

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final session = view.session;
    // Nothing is shown before a connection has been verified. An empty
    // panel full of "Not tested" is noise; the honest thing when there is
    // no session is to say nothing.
    if (!view.isConnected && !view.isBusy && session.startedAt == null) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final duration = session.duration;
    final connected = VgStatusColors.of(toneOf(view.state), theme.brightness);

    return VgPanel(
      title: l10n.get('sessionTitle'),
      icon: Icons.insights_rounded,
      uppercase: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: VgStat(
                  // Never call it "connected for" before there is a
                  // session to count from: a build-up panel that says
                  // "Connected for —" while the tunnel is still
                  // coming up claims something that has not happened.
                  label: view.isConnected
                      ? l10n.get('sessionConnectedFor')
                      : l10n.get('sessionSession'),
                  value: duration == null ? '—' : _duration(duration),
                  icon: Icons.schedule_rounded,
                  tone: view.isConnected ? connected.accent : null,
                ),
              ),
              const SizedBox(width: VgSpace.sm),
              Expanded(
                child: VgStat(
                  label: l10n.get('sessionDownloaded'),
                  value: _bytes(session.rxBytes),
                  icon: Icons.south_rounded,
                ),
              ),
              const SizedBox(width: VgSpace.sm),
              Expanded(
                child: VgStat(
                  label: l10n.get('sessionUploaded'),
                  value: _bytes(session.txBytes),
                  icon: Icons.north_rounded,
                ),
              ),
            ],
          ),
          const SizedBox(height: VgSpace.md),
          VgSurface(
            outlined: true,
            padding: const EdgeInsets.symmetric(
              horizontal: VgSpace.md,
              vertical: VgSpace.xs,
            ),
            child: Column(
              children: [
                VgInfoRow(
                  label: l10n.get('diagPublicIp'),
                  // The address is only ever the one the leak
                  // check actually read. When it has not been read,
                  // it says so rather than showing a placeholder
                  // that looks like an address.
                  value: session.assignedIpv4 ?? l10n.get('sessionNotVerified'),
                  icon: Icons.public_rounded,
                  monospace: session.assignedIpv4 != null,
                ),
                Divider(color: theme.colorScheme.outline, height: 1),
                VgInfoRow(
                  label: l10n.get('diagIpv6'),
                  // The policy, not a claim about what is
                  // happening on the wire: "blocked" is a setting
                  // this app enforces, and saying so precisely is
                  // honest where "your IPv6 is safe" would not be.
                  value: _ipv6Label(view, l10n),
                  icon: Icons.hub_outlined,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _ipv6Label(ConnectionView view, L10n l10n) =>
      switch (view.ipv6Policy) {
        Ipv6Mode.block => l10n.get('sessionIpv6Blocked'),
        Ipv6Mode.allow => l10n.get('sessionIpv6Allowed'),
        Ipv6Mode.preferTunnel => l10n.get('sessionIpv6ThroughTunnel'),
      };

  static String _duration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    final padded = s.toString().padLeft(2, '0');
    if (h > 0) {
      return '${h}h ${m.toString().padLeft(2, '0')}m';
    }
    if (m > 0) {
      return '$m:$padded';
    }
    return '0:$padded';
  }

  static String _bytes(int count) {
    if (count <= 0) {
      return '0 B';
    }
    if (count < 1024) {
      return '$count B';
    }
    if (count < 1024 * 1024) {
      return '${(count / 1024).toStringAsFixed(1)} KB';
    }
    if (count < 1024 * 1024 * 1024) {
      return '${(count / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(count / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}
