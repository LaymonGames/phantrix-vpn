import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:phantrix_core/phantrix_core.dart';
import 'package:phantrix_platform/phantrix_platform.dart';

import '../../../settings/settings_controller.dart';
import '../../../theme/tokens.dart';
import '../../../vpn/connection_controller.dart';
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
/// Edits are a draft. Nothing is persisted until Save, so a search or an
/// accidental checkbox tap cannot silently change a running tunnel's policy.
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
  late SplitTunnelSettings _draft;
  final TextEditingController _search = TextEditingController();
  final Map<String, Future<Uint8List?>> _icons = {};
  List<InstalledApp> _installed = const [];
  bool _loading = true;
  bool _saving = false;

  bool get _supported =>
      widget.connection.capabilities.supportsPerAppSplitTunnelling;

  @override
  void initState() {
    super.initState();
    _draft = widget.settings.data.splitTunnel;
    _loadInstalled();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
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
    setState(() {
      _draft = _draft.contains(app.path)
          ? _draft.withoutPath(app.path)
          : _draft.withApp(app);
    });
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
    setState(() {
      _draft = _draft.withApp(app);
    });
  }

  Future<void> _save() async {
    final l10n = context.l10n;
    final validated = _draft.validated();
    if (validated.needsAttention) {
      _notice(l10n.get('splitNeedsApps'));
      return;
    }
    setState(() => _saving = true);
    widget.settings.update((settings) {
      return settings.copyWith(splitTunnel: validated);
    });
    String message = l10n.get('splitSavedNext');
    if (widget.connection.hasLiveTunnel) {
      final result = await widget.connection.applySplitTunnel(validated);
      final error = result.errorOrNull;
      message = error == null
          ? l10n.get('splitLiveApplied')
          : l10n.get('splitApplyFailed', {'message': error.message});
    }
    if (!mounted) {
      return;
    }
    setState(() => _saving = false);
    _notice(message);
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
    final selected = {for (final app in _draft.apps) app.canonical};
    final rows = <_PickerRow>[
      for (final app in _draft.apps)
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

    return VgContentColumn(
      child: ListView(
        padding: const EdgeInsets.only(top: VgSpace.sm, bottom: VgSpace.xxl),
        children: [
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
                  value: _draft.enabled,
                  enabled: _supported,
                  disabledReason: l10n.get('splitUnsupported'),
                  onChanged: (value) {
                    setState(() {
                      _draft = _draft.copyWith(enabled: value);
                    });
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
              ],
            ),
          ),
          if (_draft.enabled) ...[
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
                        selected: _draft.mode == SplitTunnelMode.include,
                        onTap: () {
                          setState(() {
                            _draft = _draft.copyWith(
                              mode: SplitTunnelMode.include,
                            );
                          });
                        },
                      ),
                      VgSegment(
                        label: l10n.get('splitModeExclude'),
                        selected: _draft.mode == SplitTunnelMode.exclude,
                        onTap: () {
                          setState(() {
                            _draft = _draft.copyWith(
                              mode: SplitTunnelMode.exclude,
                            );
                          });
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: VgSpace.md),
                  Text(
                    _draft.mode == SplitTunnelMode.include
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
              icon: _draft.mode == SplitTunnelMode.include
                  ? Icons.vpn_lock_rounded
                  : Icons.public_rounded,
              uppercase: true,
              trailing: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(
                      l10n.get('splitSelected', {
                        'count': '${_draft.apps.length}',
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
            const SizedBox(height: VgSpace.lg),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: FilledButton.icon(
                onPressed: _saving || !_supported ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_outlined, size: VgIcon.sm),
                label: Text(l10n.get('splitSave')),
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
    return ListTile(
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
