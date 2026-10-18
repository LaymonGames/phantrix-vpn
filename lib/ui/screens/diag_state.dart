part of 'diagnostics_screen.dart';

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  List<DiagRow> _rows = const [];
  bool _running = false;

  /// The placeholder rows shown before the first run. Resolved per build
  /// (not a const field) so a language switch re-renders them too.
  static List<DiagRow> _untestedRows(L10n l10n) => [
    DiagRow(
      id: 'ip',
      title: l10n.get('diagPublicIp'),
      status: DiagStatus.notTested,
    ),
    DiagRow(
      id: 'vpn',
      title: l10n.get('diagVpnAssignedIp'),
      status: DiagStatus.notTested,
    ),
    DiagRow(
      id: 'ipv4',
      title: l10n.get('diagIpv4'),
      status: DiagStatus.notTested,
    ),
    DiagRow(
      id: 'ipv6',
      title: l10n.get('diagIpv6'),
      status: DiagStatus.notTested,
    ),
    DiagRow(
      id: 'dns',
      title: l10n.get('diagDns'),
      status: DiagStatus.notTested,
    ),
    DiagRow(
      id: 'tunnel',
      title: l10n.get('diagTunnel'),
      status: DiagStatus.notTested,
    ),
    DiagRow(
      id: 'kill',
      title: l10n.get('diagKillSwitch'),
      status: DiagStatus.notTested,
    ),
  ];

  @override
  void initState() {
    super.initState();
    _rows = const [];
  }

  Future<void> _run() async {
    setState(() => _running = true);
    // Captured before the awaits so the copy does not mix languages if the
    // switch lands mid-run; the rows render whatever run produced them.
    final l10n = context.l10n;
    final platform = await widget.connection.capabilities();
    final connected = widget.connection.isConnected;
    final verifiedIp = widget.connection.verifiedExitIp;

    // One real request to an address service — the same probe the connect
    // flow runs. It learns this device's address; that unavoidable
    // disclosure is documented in PRIVACY.md.
    final publicIp = await widget.connection.readPublicIp();

    final rows = <DiagRow>[
      DiagRow(
        id: 'ip',
        title: l10n.get('diagPublicIp'),
        value: publicIp ?? l10n.get('diagCouldNotMeasure'),
        status: publicIp == null
            ? DiagStatus.notTested
            : connected
            ? DiagStatus.passed
            : DiagStatus.warning,
        detail: connected
            ? l10n.get('diagIpExternalDetail')
            : l10n.get('diagIpDirectDetail'),
      ),
      DiagRow(
        id: 'vpn',
        title: l10n.get('diagVpnAssignedIp'),
        status: verifiedIp == null ? DiagStatus.notTested : DiagStatus.passed,
        value: verifiedIp == null
            ? l10n.get('diagVpnNotVerifiedValue')
            : l10n.get('diagVpnVerifiedValue'),
        detail: verifiedIp == null
            ? l10n.get('diagVpnNotVerifiedDetail')
            : l10n.get('diagVpnVerifiedDetail'),
      ),
      DiagRow(
        id: 'ipv4',
        title: l10n.get('diagIpv4'),
        status: verifiedIp == null ? DiagStatus.notTested : DiagStatus.passed,
        detail: verifiedIp == null
            ? l10n.get('diagIpv4NotVerifiedDetail')
            : l10n.get('diagIpv4VerifiedDetail'),
      ),
      DiagRow(
        id: 'ipv6',
        title: l10n.get('diagIpv6'),
        status: platform.supportsIpv6Blocking
            ? DiagStatus.passed
            : DiagStatus.notSupported,
        value: platform.supportsIpv6Blocking
            ? l10n.get('diagIpv6BlockedValue')
            : null,
        detail: platform.supportsIpv6Blocking
            ? l10n.get('diagIpv6BlockedDetail')
            : l10n.get('diagIpv6NotSupportedDetail'),
      ),
      DiagRow(
        id: 'dns',
        title: l10n.get('diagDns'),
        status: DiagStatus.notSupported,
        detail: l10n.get('diagDnsDetail'),
      ),
      DiagRow(
        id: 'tunnel',
        title: l10n.get('diagTunnel'),
        status: connected ? DiagStatus.passed : DiagStatus.notTested,
        detail: connected
            ? l10n.get('diagTunnelVerifiedDetail')
            : l10n.get('diagTunnelNoTunnelDetail'),
      ),
      DiagRow(
        id: 'kill',
        title: l10n.get('diagKillSwitch'),
        status: platform.supportsKillSwitch
            ? DiagStatus.passed
            : DiagStatus.notSupported,
        detail: platform.supportsKillSwitch
            ? l10n.get('diagKillSwitchVerifiedDetail')
            : l10n.get('diagKillSwitchNotSupportedDetail'),
      ),
    ];

    if (!mounted) {
      return;
    }
    setState(() {
      _rows = rows;
      _running = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final rows = _rows.isEmpty ? _untestedRows(l10n) : _rows;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        VgContentColumn(
          child: Padding(
            padding: const EdgeInsets.only(top: VgSpace.sm, bottom: VgSpace.md),
            child: VgPanel(
              padding: const EdgeInsets.all(VgSpace.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.get('amIProtected'),
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: VgSpace.xs),
                  Text(
                    l10n.get('leakExplanation'),
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: VgSpace.md),
                  FilledButton.icon(
                    onPressed: _running ? null : _run,
                    icon: _running
                        ? const SizedBox(
                            width: VgIcon.sm,
                            height: VgIcon.sm,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(
                            Icons.health_and_safety_rounded,
                            size: VgIcon.sm,
                          ),
                    label: Text(l10n.get('runChecks')),
                  ),
                ],
              ),
            ),
          ),
        ),
        Expanded(
          child: VgContentColumn(
            child: ListView.separated(
              padding: const EdgeInsets.only(bottom: VgSpace.xxl),
              itemCount: rows.length,
              separatorBuilder: (context, index) =>
                  const SizedBox(height: VgSpace.sm),
              itemBuilder: (context, index) => _RowCard(row: rows[index]),
            ),
          ),
        ),
      ],
    );
  }
}
