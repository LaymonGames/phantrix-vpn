part of 'home_screen.dart';

/// Says that the kill switch is holding the internet back, and offers to lift
/// it.
///
/// Shown only while the firewall rules are in place with no tunnel up, which
/// is exactly when a user who sees "no internet" needs to know why. Drawn in
/// the "attention" tone rather than as an error: the block is the feature
/// working, not a failure. Connecting from the hero still works as usual; a
/// new connection replaces the block with the tunnel.
class _KillSwitchCard extends StatefulWidget {
  const _KillSwitchCard({required this.strict, required this.onUnblock});

  /// The strict kill switch is the one blocking (it outlives Disconnect and
  /// restarts), as opposed to the automatic one holding after a drop.
  final bool strict;

  /// Lifts the block. On Windows this asks for administrator approval.
  final Future<Result<void>> Function() onUnblock;

  @override
  State<_KillSwitchCard> createState() => _KillSwitchCardState();
}

class _KillSwitchCardState extends State<_KillSwitchCard> {
  bool _busy = false;
  bool _failed = false;

  Future<void> _unblock() async {
    setState(() {
      _busy = true;
      _failed = false;
    });
    final result = await widget.onUnblock();
    if (!mounted) {
      return;
    }
    setState(() {
      _busy = false;
      _failed = result.errorOrNull != null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);
    final accent = VgStatusColors.of(VgTone.blocked, theme.brightness).accent;
    return VgSurface(
      key: const ValueKey('home-kill-switch-card'),
      accent: accent,
      padding: const EdgeInsets.all(VgSpace.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.lock_outline_rounded, size: VgIcon.md, color: accent),
              const SizedBox(width: VgSpace.md),
              Expanded(
                child: Text(
                  l10n.get(
                    widget.strict
                        ? 'homeKillSwitchStrict'
                        : 'homeKillSwitchAutomatic',
                  ),
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: theme.colorScheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: VgSpace.md),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: _busy
                ? VgBusy(l10n.get('homeKillSwitchUnblocking'), compact: true)
                : FilledButton.tonal(
                    onPressed: () => unawaited(_unblock()),
                    child: Text(l10n.get('homeKillSwitchUnblock')),
                  ),
          ),
          if (_failed) ...[
            const SizedBox(height: VgSpace.sm),
            Text(
              l10n.get('killSwitchReleaseFailed'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
