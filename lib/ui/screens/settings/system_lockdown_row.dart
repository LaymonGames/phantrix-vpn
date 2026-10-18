import 'package:flutter/material.dart';

import '../../../theme/tokens.dart';
import '../../components/status_style.dart';
import '../../shell.dart';

/// The operating system's own traffic-blocking state, read live.
///
/// This row exists because the app cannot block traffic itself: the only
/// genuine kill switch on stock Android is Always-on VPN with "Block
/// connections without VPN", and it lives in the system settings. So the row
/// reports what the system says and links there, rather than offering a
/// switch here that could not honour itself.
///
/// Shown only on Android. Every other platform has no equivalent reading, and
/// a row that always says "off" with nowhere to enable it would be noise.
class SystemLockdownRow extends StatefulWidget {
  const SystemLockdownRow({
    required this.systemLockdownActive,
    required this.onOpenSystemVpnSettings,
    super.key,
  });

  final Future<bool> Function() systemLockdownActive;
  final VoidCallback onOpenSystemVpnSettings;

  @override
  State<SystemLockdownRow> createState() => _SystemLockdownRowState();
}

class _SystemLockdownRowState extends State<SystemLockdownRow> {
  late final Future<bool> _active = widget.systemLockdownActive();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    // The future is created once in `initState`, not on every build: a
    // rebuild caused by an unrelated settings toggle must not flash the
    // row back to "off" while it re-reads. Returning to this screen
    // creates a new state and re-reads, so the value is still live per
    // visit rather than cached for the session.
    return FutureBuilder<bool>(
      future: _active,
      builder: (context, snapshot) {
        final active = snapshot.data ?? false;
        final tone = active ? VgTone.connected : VgTone.idle;
        return Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: VgSpace.lg,
            vertical: VgSpace.md,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    active
                        ? Icons.verified_user_rounded
                        : Icons.info_outline_rounded,
                    size: VgIcon.sm,
                    color: active
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: VgSpace.sm),
                  Expanded(
                    child: Text(
                      l10n.get('settingsSystemLockdown'),
                      style: theme.textTheme.bodyLarge,
                    ),
                  ),
                  const SizedBox(width: VgSpace.sm),
                  Text(
                    active
                        ? l10n.get('settingsSystemLockdownOn')
                        : l10n.get('settingsSystemLockdownOff'),
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: VgStatusColors.of(tone, theme.brightness).accent,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: VgSpace.xs),
              Text(
                active
                    ? l10n.get('settingsSystemLockdownOnHint')
                    : l10n.get('settingsSystemLockdownOffHint'),
                style: theme.textTheme.bodySmall,
              ),
              // The future may still be in flight on first
              // build; the row shows the last-known state
              // (off) rather than a spinner, because a
              // spinner here would read as "protection is
              // being set up" when nothing of the sort is
              // happening.
              if (!active) ...[
                const SizedBox(height: VgSpace.sm),
                OutlinedButton.icon(
                  onPressed: widget.onOpenSystemVpnSettings,
                  icon: const Icon(Icons.open_in_new_rounded, size: VgIcon.sm),
                  label: Text(l10n.get('settingsOpenVpnSettings')),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
