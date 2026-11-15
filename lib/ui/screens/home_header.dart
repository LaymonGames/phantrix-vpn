part of 'home_screen.dart';

/// Where the tunnel goes, in words: the live destination while connecting or
/// connected, otherwise the saved preference.
String _locationLabel(
  ConnectionView view,
  String selectedCountryCode,
  L10n l10n,
) {
  final raw = view.selectedLabel;
  if ((view.isConnected || view.isBusy) && raw != null) {
    return (GeoDatabase.byIso2(raw) != null || GeoDatabase.byIso3(raw) != null)
        ? GeoDatabase.nameOf(raw, l10n.languageCode)
        : raw;
  }
  return selectedCountryCode == 'AUTO'
      ? l10n.get('automaticLocation')
      : GeoDatabase.nameOf(selectedCountryCode, l10n.languageCode);
}

/// The sentence at the top of the dashboard: protected or not, in words.
///
/// A VPN's one question is "am I protected right now?". The orb answers it
/// with colour and a glyph; this answers it with a headline anyone can read
/// at a glance, so the state never depends on recognising a colour.
class _StatusHeader extends StatelessWidget {
  const _StatusHeader({required this.view, required this.location});

  final ConnectionView view;
  final String location;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);
    final tone = toneOf(view.state);
    // Unprotected is a risk, not a neutral state: the header says so in the
    // warning colour, while the orb keeps inviting the tap that fixes it.
    final colors = VgStatusColors.of(
      tone == VgTone.idle ? VgTone.blocked : tone,
      theme.brightness,
    );
    final (head, sub) = switch (tone) {
      VgTone.idle => ('homeHeadIdle', 'homeSubIdle'),
      VgTone.working => ('homeHeadWorking', 'homeSubWorking'),
      VgTone.connected => ('homeHeadConnected', 'homeSubConnected'),
      VgTone.failed => ('homeHeadFailed', 'homeSubFailed'),
      VgTone.blocked => ('homeHeadBlocked', 'homeSubBlocked'),
    };
    final narrow = MediaQuery.sizeOf(context).width < 600;
    return Semantics(
      liveRegion: true,
      header: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          AnimatedContainer(
            duration: VgMotion.normal,
            curve: VgMotion.standard,
            width: narrow ? 44 : 52,
            height: narrow ? 44 : 52,
            decoration: BoxDecoration(
              color: colors.accent.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(VgRadius.md),
              border: Border.all(color: colors.accent.withValues(alpha: 0.30)),
            ),
            child: Icon(
              tone == VgTone.idle ? Icons.gpp_maybe_outlined : colors.icon,
              color: colors.accent,
              size: narrow ? 22 : 26,
            ),
          ),
          const SizedBox(width: VgSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedSwitcher(
                  duration: VgMotion.normal,
                  child: Text(
                    l10n.get(head),
                    key: ValueKey(head),
                    style:
                        (narrow
                                ? theme.textTheme.headlineSmall
                                : theme.textTheme.headlineMedium)
                            ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(height: VgSpace.xxs),
                Text(
                  l10n.get(sub, {'location': location}),
                  style: theme.textTheme.bodyMedium,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// What protects the user beyond the tunnel itself, at a glance.
///
/// Read-only on purpose: the switches live in Settings, and the card links
/// there. A dashboard that can flip the kill switch with one stray click is
/// a dashboard that can silently remove protection.
class _ProtectionPanel extends StatelessWidget {
  const _ProtectionPanel({
    required this.view,
    required this.settings,
    required this.onOpenSettings,
  });

  final ConnectionView view;
  final AppSettings settings;
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final theme = Theme.of(context);
    final good = VgStatusColors.of(VgTone.connected, theme.brightness).accent;
    final warn = VgStatusColors.of(VgTone.blocked, theme.brightness).accent;
    final muted = theme.colorScheme.onSurfaceVariant;

    final killSupported = view.platform.supportsKillSwitch;
    final (killValue, killColor) = !killSupported
        ? (l10n.get('protectionUnavailable'), muted)
        : switch (settings.killSwitch) {
            KillSwitchMode.off => (l10n.get('protectionOff'), warn),
            KillSwitchMode.automatic => (l10n.get('killSwitchAutomatic'), good),
            KillSwitchMode.strict => (l10n.get('killSwitchStrict'), good),
          };

    final split = settings.splitTunnel;
    final splitSupported = view.platform.supportsPerAppSplitTunnelling;
    final (splitValue, splitColor) = !splitSupported
        ? (l10n.get('protectionUnavailable'), muted)
        : !split.enabled
        ? (l10n.get('protectionOff'), muted)
        : (
            l10n.get(
              split.mode == SplitTunnelMode.include
                  ? 'protectionSplitInclude'
                  : 'protectionSplitExclude',
              {'count': '${split.apps.length}'},
            ),
            theme.colorScheme.primary,
          );

    final (ipv6Value, ipv6Color) = switch (settings.ipv6) {
      Ipv6Mode.block => (l10n.get('ipv6Block'), good),
      Ipv6Mode.preferTunnel => (l10n.get('ipv6Prefer'), good),
      Ipv6Mode.allow => (l10n.get('ipv6Allow'), warn),
    };

    return VgPanel(
      title: l10n.get('protectionTitle'),
      icon: Icons.verified_user_outlined,
      uppercase: true,
      trailing: onOpenSettings == null
          ? null
          : IconButton(
              tooltip: l10n.get('protectionManage'),
              onPressed: onOpenSettings,
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              icon: const Icon(Icons.tune_rounded, size: VgIcon.sm),
            ),
      child: Column(
        children: [
          _ProtectionRow(
            icon: Icons.block_rounded,
            label: l10n.get('protectionKillSwitch'),
            value: killValue,
            color: killColor,
          ),
          _ProtectionRow(
            icon: Icons.call_split_rounded,
            label: l10n.get('protectionSplit'),
            value: splitValue,
            color: splitColor,
          ),
          _ProtectionRow(
            icon: Icons.dns_outlined,
            label: l10n.get('protectionDns'),
            value: l10n.get('protectionDnsValue'),
            color: good,
          ),
          _ProtectionRow(
            icon: Icons.language_rounded,
            label: l10n.get('protectionIpv6'),
            value: ipv6Value,
            color: ipv6Color,
            last: true,
          ),
        ],
      ),
    );
  }
}

class _ProtectionRow extends StatelessWidget {
  const _ProtectionRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
    this.last = false,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color color;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : VgSpace.sm),
      child: Row(
        children: [
          Icon(icon, size: VgIcon.sm, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: VgSpace.md),
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodyLarge,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: VgSpace.sm),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: VgSpace.sm,
                vertical: VgSpace.xxs + 1,
              ),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(VgRadius.pill),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: VgSpace.xs + 2),
                  Flexible(
                    child: Text(
                      value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: color,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
