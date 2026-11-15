import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:phantrix_core/phantrix_core.dart';
import 'package:phantrix_platform/phantrix_platform.dart';

import '../../../settings/settings_controller.dart';
import '../../../theme/tokens.dart';
import '../../../vpn/connection_controller.dart';
import '../../components/vg_page_title.dart';
import '../../components/containers.dart';
import '../../components/rows.dart';
import '../../components/surfaces.dart';
import '../../shell.dart';

/// The split-tunnel picker.
///
/// A dedicated screen rather than a settings row that expands: choosing
/// applications needs a search field, icons and a scrollable list, and none of
/// those belong inside a list of switches.
///
/// Every edit is stored the moment it is made, through the settings
/// controller, so leaving the screen can never lose a choice and the switch on
/// the settings screen always shows the same state as this one. A running
/// tunnel is updated after a short pause rather than on every tap, and any
/// pending update is sent when the screen is closed.
class SplitTunnelingScreen extends StatefulWidget {
  const SplitTunnelingScreen({
    required this.settings,
    required this.connection,
    super.key,
  });

  final SettingsController settings;
  final ConnectionController connection;

  @override
  State<SplitTunnelingScreen> createState() => _SplitTunnelingScreenState();
}

class _SplitTunnelingScreenState extends State<SplitTunnelingScreen> {
  /// How long a burst of edits waits before reaching a running tunnel.
  ///
  /// Each tap is stored at once; only the native policy update is held back,
  /// so ticking five applications sends one policy rather than five.
  static const Duration liveApplyDelay = Duration(milliseconds: 600);

  final TextEditingController _search = TextEditingController();
  final Map<String, Future<Uint8List?>> _icons = {};
  List<InstalledApp> _installed = const [];
  bool _loading = true;
  bool _applying = false;
  Timer? _liveApply;

  bool get _supported =>
      widget.connection.capabilities.supportsPerAppSplitTunnelling;

  /// The stored policy. Read live rather than copied, so a change made on the
  /// settings screen shows here and nothing on this screen can drift from it.
  SplitTunnelSettings get _policy => widget.settings.data.splitTunnel;

  @override
  void initState() {
    super.initState();
    widget.settings.addListener(_onSettingsChanged);
    _loadInstalled();
  }

  @override
  void didUpdateWidget(SplitTunnelingScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.settings != widget.settings) {
      oldWidget.settings.removeListener(_onSettingsChanged);
      widget.settings.addListener(_onSettingsChanged);
    }
  }

  @override
  void dispose() {
    widget.settings.removeListener(_onSettingsChanged);
    // The choice is already stored; what may still be pending is pushing it
    // to a running tunnel. Send it now rather than dropping it with the
    // screen.
    if (_liveApply?.isActive ?? false) {
      _liveApply!.cancel();
      unawaited(_pushToTunnel(_policy));
    }
    _search.dispose();
    super.dispose();
  }

  void _onSettingsChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  /// Stores [next] at once and schedules it for a running tunnel.
  void _commit(SplitTunnelSettings next) {
    final validated = next.validated();
    widget.settings.update((s) => s.copyWith(splitTunnel: validated));
    _liveApply?.cancel();
    if (!widget.connection.hasLiveTunnel) {
      return;
    }
    _liveApply = Timer(liveApplyDelay, () => unawaited(_applyLive()));
  }

  /// Sends [policy] to the running tunnel, answering null when there is
  /// nothing to send it to or nothing that should be sent.
  ///
  /// Include mode with nothing selected is stored but not applied: it would
  /// route nothing through the VPN, and the screen says so instead.
  Future<Result<void>?> _pushToTunnel(SplitTunnelSettings policy) async {
    if (!_supported ||
        policy.needsAttention ||
        !widget.connection.hasLiveTunnel) {
      return null;
    }
    return widget.connection.applySplitTunnel(policy);
  }

  Future<void> _applyLive() async {
    if (!mounted) {
      return;
    }
    setState(() => _applying = true);
    final result = await _pushToTunnel(_policy);
    if (!mounted) {
      return;
    }
    setState(() => _applying = false);
    final error = result?.errorOrNull;
    if (error != null) {
      _notice(context.l10n.get('splitApplyFailed', {'message': error.message}));
    }
  }

  Future<void> _loadInstalled() async {
    final apps = await widget.connection.platform.listInstalledApps();
    if (!mounted) {
      return;
    }
    setState(() {
      _installed = apps;
      _loading = false;
    });
  }

  Future<Uint8List?> _iconFor(String path) =>
      _icons.putIfAbsent(path, () async {
        final raw = await widget.connection.platform.appIcon(path);
        if (raw == null || raw.isEmpty) {
          return null;
        }
        try {
          return base64Decode(raw);
        } on FormatException {
          return null;
        }
      });

  void _toggle(SplitTunnelApp app) {
    final policy = _policy;
    _commit(
      policy.contains(app.path)
          ? policy.withoutPath(app.path)
          : policy.withApp(app),
    );
  }

  Future<void> _browse() async {
    final path = await widget.connection.platform.pickExecutable();
    if (path == null || path.trim().isEmpty) {
      return;
    }
    final separator = path.lastIndexOf(RegExp(r'[\\/]'));
    final file = separator < 0 ? path : path.substring(separator + 1);
    final name = file.toLowerCase().endsWith('.exe')
        ? file.substring(0, file.length - 4)
        : file;
    final app = SplitTunnelApp(path: path, name: name);
    if (!app.isValid) {
      return;
    }
    _commit(_policy.withApp(app));
  }

  void _notice(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final query = _search.text.trim().toLowerCase();
    final policy = _policy;
    final selected = {for (final app in policy.apps) app.canonical};
    final rows = <_PickerRow>[
      for (final app in policy.apps)
        if (query.isEmpty ||
            app.name.toLowerCase().contains(query) ||
            app.path.toLowerCase().contains(query))
          _PickerRow(app: app, selected: true),
      for (final app in _installed)
        if (!selected.contains(app.path.toLowerCase()) &&
            (query.isEmpty ||
                app.name.toLowerCase().contains(query) ||
                app.path.toLowerCase().contains(query)))
          _PickerRow(
            app: SplitTunnelApp(path: app.path, name: app.name),
            selected: false,
          ),
    ];

    // Full-width scroll view so the wheel works over the page margins too.
    return VgScrollColumn(
      builder: (context, insets) => ListView(
        padding: insets.copyWith(top: VgSpace.sm, bottom: VgSpace.xxl),
        children: [
          VgPageTitle(title: l10n.get('settingsSplitTunneling')),
          VgPanel(
            title: l10n.get('settingsSplitTunneling'),
            icon: Icons.call_split_rounded,
            uppercase: true,
            padding: const EdgeInsets.symmetric(vertical: VgSpace.sm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                VgToggleRow(
                  title: l10n.get('splitEnable'),
                  subtitle: l10n.get('splitEnableHint'),
                  value: policy.enabled,
                  enabled: _supported,
                  disabledReason: l10n.get('splitUnsupported'),
                  onChanged: (value) {
                    _commit(policy.copyWith(enabled: value));
                  },
                ),
                if (!_supported)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: VgSpace.lg,
                      vertical: VgSpace.xs,
                    ),
                    child: Text(
                      l10n.get('splitUnsupported'),
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                if (_supported && policy.needsAttention)
                  Padding(
                    padding: const EdgeInsets.only(bottom: VgSpace.sm),
                    child: Text(
                      l10n.get('splitNeedsApps'),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (policy.enabled) ...[
            const SizedBox(height: VgSpace.lg),
            VgPanel(
              title: l10n.get('splitMode'),
              icon: Icons.alt_route_rounded,
              uppercase: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: VgSpace.sm,
                    runSpacing: VgSpace.sm,
                    children: [
                      VgSegment(
                        label: l10n.get('splitModeInclude'),
                        selected: policy.mode == SplitTunnelMode.include,
                        onTap: () {
                          _commit(
                            policy.copyWith(mode: SplitTunnelMode.include),
                          );
                        },
                      ),
                      VgSegment(
                        label: l10n.get('splitModeExclude'),
                        selected: policy.mode == SplitTunnelMode.exclude,
                        onTap: () {
                          _commit(
                            policy.copyWith(mode: SplitTunnelMode.exclude),
                          );
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: VgSpace.md),
                  Text(
                    policy.mode == SplitTunnelMode.include
                        ? l10n.get('splitModeIncludeHint')
                        : l10n.get('splitModeExcludeHint'),
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(height: VgSpace.lg),
            VgPanel(
              title: l10n.get('splitAppsUseVpn'),
              icon: policy.mode == SplitTunnelMode.include
                  ? Icons.vpn_lock_rounded
                  : Icons.public_rounded,
              uppercase: true,
              trailing: _applying
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(
                      l10n.get('splitSelected', {
                        'count': '${policy.apps.length}',
                      }),
                      style: theme.textTheme.labelSmall,
                    ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _search,
                          onChanged: (_) => setState(() {}),
                          decoration: InputDecoration(
                            hintText: l10n.get('splitSearchHint'),
                            prefixIcon: const Icon(
                              Icons.search_rounded,
                              size: VgIcon.sm,
                            ),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: VgSpace.sm),
                      OutlinedButton.icon(
                        onPressed: _browse,
                        icon: const Icon(Icons.add_rounded, size: VgIcon.sm),
                        label: Text(l10n.get('splitBrowse')),
                      ),
                    ],
                  ),
                  const SizedBox(height: VgSpace.sm),
                  Text(
                    l10n.get('splitMissingHint'),
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: VgSpace.sm),
                  if (_loading)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: VgSpace.lg),
                      child: Row(
                        children: [
                          const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          const SizedBox(width: VgSpace.md),
                          Text(l10n.get('splitLoading')),
                        ],
                      ),
                    )
                  else if (rows.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: VgSpace.lg),
                      child: Text(
                        query.isEmpty
                            ? l10n.get('splitEmpty')
                            : l10n.get('splitNoMatches'),
                        style: theme.textTheme.bodyMedium,
                      ),
                    )
                  else
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 420),
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: rows.length,
                        separatorBuilder: (_, _) => Divider(
                          color: theme.colorScheme.outline,
                          height: 1,
                        ),
                        itemBuilder: (context, index) {
                          final row = rows[index];
                          return _AppRow(
                            key: ValueKey(row.app.path.toLowerCase()),
                            app: row.app,
                            selected: row.selected,
                            icon: _iconFor(row.app.path),
                            onToggle: () => _toggle(row.app),
                            onRemove: row.selected
                                ? () => _toggle(row.app)
                                : null,
                            removeLabel: l10n.get('splitRemove'),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PickerRow {
  const _PickerRow({required this.app, required this.selected});

  final SplitTunnelApp app;
  final bool selected;
}

class _AppRow extends StatelessWidget {
  const _AppRow({
    required this.app,
    required this.selected,
    required this.icon,
    required this.onToggle,
    required this.onRemove,
    required this.removeLabel,
    super.key,
  });

  final SplitTunnelApp app;
  final bool selected;
  final Future<Uint8List?> icon;
  final VoidCallback onToggle;
  final VoidCallback? onRemove;
  final String removeLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Its own transparent Material: the panel's surface is a decorated box,
    // which would otherwise hide the tile's ink and trips ListTile's check.
    return Material(
      type: MaterialType.transparency,
      child: ListTile(
        onTap: onToggle,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: VgSpace.xs,
          vertical: 0,
        ),
        minTileHeight: 60,
        leading: _AppIcon(icon: icon),
        title: Text(app.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          app.path,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Checkbox(value: selected, onChanged: (_) => onToggle()),
            if (onRemove != null)
              IconButton(
                tooltip: removeLabel,
                visualDensity: VisualDensity.compact,
                onPressed: onRemove,
                icon: Icon(
                  Icons.remove_circle_outline_rounded,
                  size: VgIcon.sm,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _AppIcon extends StatelessWidget {
  const _AppIcon({required this.icon});

  final Future<Uint8List?> icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 32,
      height: 32,
      child: FutureBuilder<Uint8List?>(
        future: icon,
        builder: (context, snapshot) {
          final bytes = snapshot.data;
          if (bytes != null && bytes.isNotEmpty) {
            return Image.memory(
              bytes,
              width: 32,
              height: 32,
              fit: BoxFit.contain,
            );
          }
          return DecoratedBox(
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(VgRadius.sm),
            ),
            child: Icon(
              Icons.apps_rounded,
              size: VgIcon.sm,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          );
        },
      ),
    );
  }
}
