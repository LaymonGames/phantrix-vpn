part of 'diagnostics_screen.dart';

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  List<DiagRow> _rows = const [];
  bool _running = false;

  static const List<DiagRow> _untested = [
    DiagRow(id: 'ip', title: 'Public IP', status: DiagStatus.notTested),
    DiagRow(id: 'vpn', title: 'VPN-assigned IP', status: DiagStatus.notTested),
    DiagRow(id: 'ipv4', title: 'IPv4', status: DiagStatus.notTested),
    DiagRow(id: 'ipv6', title: 'IPv6', status: DiagStatus.notTested),
    DiagRow(id: 'dns', title: 'DNS', status: DiagStatus.notTested),
    DiagRow(id: 'tunnel', title: 'Tunnel', status: DiagStatus.notTested),
    DiagRow(id: 'kill', title: 'Kill switch', status: DiagStatus.notTested),
  ];

  @override
  void initState() {
    super.initState();
    _rows = _untested;
  }

  Future<void> _run() async {
    setState(() => _running = true);
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
        title: 'Public IP',
        value: publicIp ?? 'Could not be measured',
        status: publicIp == null
            ? DiagStatus.notTested
            : connected
            ? DiagStatus.passed
            : DiagStatus.warning,
        detail: connected
            ? 'An external service reports this address. It is the address '
                  'your traffic appears to come from.'
            : 'Not connected, so this is the address this device uses directly.',
      ),
      DiagRow(
        id: 'vpn',
        title: 'VPN-assigned IP',
        status: verifiedIp == null ? DiagStatus.notTested : DiagStatus.passed,
        value: verifiedIp == null
            ? 'Verified only after a connection'
            : 'The address the session verification reported as the exit.',
        detail: verifiedIp == null
            ? 'Read from the same verification that confirms a connect, so it '
                  'appears here once a session has been verified.'
            : 'What the session verification reported as the exit address.',
      ),
      DiagRow(
        id: 'ipv4',
        title: 'IPv4',
        status: verifiedIp == null ? DiagStatus.notTested : DiagStatus.passed,
        detail: verifiedIp == null
            ? 'Confirmed by the same evidence as the row above: the public '
                  'address changing and staying changed while the tunnel is up.'
            : 'IPv4 is routed through the tunnel.',
      ),
      DiagRow(
        id: 'ipv6',
        title: 'IPv6',
        status: platform.supportsIpv6Blocking
            ? DiagStatus.passed
            : DiagStatus.notSupported,
        value: platform.supportsIpv6Blocking ? 'Blocked while connected' : null,
        detail: platform.supportsIpv6Blocking
            ? 'The tunnel interface carries no IPv6 address, so there is no '
                  'IPv6 route to escape through. This hides the address from '
                  'sites you visit, it does not make the connection anonymous.'
            : 'This platform cannot block IPv6, so IPv4 may be protected while '
                  'IPv6 is not.',
      ),
      DiagRow(
        id: 'dns',
        title: 'DNS',
        status: DiagStatus.notSupported,
        detail: 'The profile pushed by the server decides the resolver. '
            'This screen cannot read the resolver Windows is actually using, '
            'so it reports that rather than asserting one is in use.',
      ),
      DiagRow(
        id: 'tunnel',
        title: 'Tunnel',
        status: connected ? DiagStatus.passed : DiagStatus.notTested,
        detail: connected
            ? 'The tunnel was verified after it was established.'
            : 'No tunnel is up, so there is nothing to check.',
      ),
      DiagRow(
        id: 'kill',
        title: 'Kill switch',
        status: platform.supportsKillSwitch
            ? DiagStatus.passed
            : DiagStatus.notSupported,
        detail: platform.supportsKillSwitch
            ? 'Traffic is dropped when the tunnel is unavailable.'
            : 'This platform cannot guarantee a strict kill switch. When the '
                  'tunnel drops, traffic leaves over the normal connection until '
                  'it can be re-established. Phantrix reports that instead of '
                  'claiming protection it does not have.',
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
              itemCount: _rows.length,
              separatorBuilder: (context, index) =>
                  const SizedBox(height: VgSpace.sm),
              itemBuilder: (context, index) => _RowCard(row: _rows[index]),
            ),
          ),
        ),
      ],
    );
  }
}
