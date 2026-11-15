/// Per-application routing policy for the Windows split tunnel.
///
/// The model is deliberately platform-neutral. It answers three questions and
/// nothing else: is the feature on, which way round does it work, and which
/// executables did the user choose. Everything that turns those answers into
/// traffic rules lives in the platform layer.
library;

/// The direction of the policy.
enum SplitTunnelMode {
  /// Only the chosen applications use the tunnel. Everything else keeps the
  /// machine's normal connection.
  include('Only selected apps use the VPN'),

  /// Everything uses the tunnel except the chosen applications.
  exclude('Selected apps bypass the VPN');

  const SplitTunnelMode(this.label);

  final String label;
}

/// One executable the user picked.
///
/// Two fields, because the path alone is not what a person recognises and the
/// name alone cannot be turned into a rule. Both are trimmed and bounded at
/// construction, so a value read back from disk can never be longer than the
/// driver's own fixed buffers.
class SplitTunnelApp {
  SplitTunnelApp({required String path, String? name})
    : path = normalizePath(path),
      name = _normalizedName(name, path);

  /// The executable's absolute path, with `/` folded to `\` and surrounding
  /// quotes and whitespace removed.
  ///
  /// Windows paths are compared case-insensitively, so [==] and [hashCode]
  /// use the folded form. Two entries for the same file are one app, whichever
  /// case the shell happened to hand over.
  final String path;

  /// What the list shows. Falls back to the file name when the caller has no
  /// friendlier label.
  final String name;

  /// The part of [path] after the last separator.
  String get fileName {
    final separator = path.lastIndexOf('\\');
    return separator < 0 ? path : path.substring(separator + 1);
  }

  /// True when this entry names something the driver may route.
  ///
  /// A relative path, a path containing a quote, or anything that is not an
  /// `.exe` is refused. The driver matches the exact image path Windows
  /// reports; a value that cannot be one is not silently repaired into
  /// something else.
  bool get isValid => isValidPath(path);

  /// The canonical form used for comparison and for the driver.
  String get canonical => path.toLowerCase();

  static bool isValidPath(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty || trimmed.length > 1024) {
      return false;
    }
    if (trimmed.contains('"') || trimmed.contains('\u0000')) {
      return false;
    }
    if (!trimmed.toLowerCase().endsWith('.exe')) {
      return false;
    }
    // Absolute drive path, or a UNC path. A bare `chrome.exe` would resolve
    // against whatever directory the helper was started in, which is not the
    // application the user picked.
    final drive = RegExp(r'^[A-Za-z]:\\');
    final unc = trimmed.startsWith(r'\\');
    return drive.hasMatch(trimmed) || unc;
  }

  static String normalizePath(String value) {
    var result = value.trim();
    if (result.length >= 2 && result.startsWith('"') && result.endsWith('"')) {
      result = result.substring(1, result.length - 1).trim();
    }
    return result.replaceAll('/', r'\');
  }

  static String _normalizedName(String? name, String path) {
    final trimmed = name?.trim();
    if (trimmed != null && trimmed.isNotEmpty) {
      return trimmed.length > 160 ? trimmed.substring(0, 160) : trimmed;
    }
    final normalized = normalizePath(path);
    final separator = normalized.lastIndexOf(r'\');
    final file = separator < 0
        ? normalized
        : normalized.substring(separator + 1);
    return file.isEmpty ? normalized : file;
  }

  Map<String, Object?> toJson() => {'name': name, 'path': path};

  static SplitTunnelApp? fromJson(Object? value) {
    if (value is! Map) {
      return null;
    }
    final path = value['path'];
    if (path is! String) {
      return null;
    }
    final app = SplitTunnelApp(path: path, name: value['name'] as String?);
    return app.isValid ? app : null;
  }

  @override
  bool operator ==(Object other) =>
      other is SplitTunnelApp && other.canonical == canonical;

  @override
  int get hashCode => canonical.hashCode;

  @override
  String toString() => 'SplitTunnelApp($name, $path)';
}

/// The whole split-tunnel preference.
///
/// Immutable, like every other setting, so a change is one value the UI can
/// diff and the store can write atomically.
class SplitTunnelSettings {
  /// A const constructor so the whole settings graph can keep its `const`
  /// default. Values arriving from disk or from the UI go through
  /// [SplitTunnelSettings.validated] before they are used.
  const SplitTunnelSettings({
    this.enabled = false,
    this.mode = SplitTunnelMode.include,
    this.apps = const [],
  });

  final bool enabled;
  final SplitTunnelMode mode;

  /// Selected executables, in the order the user chose them.
  final List<SplitTunnelApp> apps;

  /// Builds a policy whose entries are validated, de-duplicated and capped.
  factory SplitTunnelSettings.normalized({
    bool enabled = false,
    SplitTunnelMode mode = SplitTunnelMode.include,
    List<SplitTunnelApp> apps = const [],
  }) => SplitTunnelSettings(
    enabled: enabled,
    mode: mode,
    apps: _normalizeApps(apps),
  );

  /// The most entries the store will carry.
  ///
  /// A bound rather than an arbitrary limit: the policy crosses a named pipe
  /// and is copied into kernel memory, so both sides need a number they can
  /// size a buffer from.
  static const int maxApps = 256;

  /// True when there is a policy to apply.
  ///
  /// Enabled with no selected applications is a valid state for exclude mode
  /// (nothing bypasses, so the tunnel behaves normally) but not for include
  /// mode: it would route nothing through the VPN. [needsAttention] reports
  /// that case to the UI without changing what was stored.
  bool get isActive => enabled && apps.isNotEmpty;

  /// Include mode with nothing selected would send no application through the
  /// tunnel. That is not a policy, so the screen says so instead of applying
  /// it.
  bool get needsAttention =>
      enabled && mode == SplitTunnelMode.include && apps.isEmpty;

  /// The selected paths, in order, for the native request.
  List<String> get paths => [for (final app in apps) app.path];

  bool contains(String path) {
    final canonical = SplitTunnelApp.normalizePath(path).toLowerCase();
    return apps.any((app) => app.canonical == canonical);
  }

  SplitTunnelSettings copyWith({
    bool? enabled,
    SplitTunnelMode? mode,
    List<SplitTunnelApp>? apps,
  }) => SplitTunnelSettings(
    enabled: enabled ?? this.enabled,
    mode: mode ?? this.mode,
    apps: apps ?? this.apps,
  );

  /// Adds [app], keeping the existing order. Adding the same executable twice
  /// is the same preference, not two entries.
  SplitTunnelSettings withApp(SplitTunnelApp app) {
    if (!app.isValid || contains(app.path) || apps.length >= maxApps) {
      return this;
    }
    return copyWith(apps: [...apps, app]);
  }

  SplitTunnelSettings withoutPath(String path) {
    final canonical = SplitTunnelApp.normalizePath(path).toLowerCase();
    return copyWith(
      apps: [
        for (final app in apps)
          if (app.canonical != canonical) app,
      ],
    );
  }

  /// Drops entries that are no longer valid.
  ///
  /// Missing files are deliberately kept. A USB drive or a network share may be
  /// absent at launch and present later, and silently deleting the user's
  /// choice because a disk was asleep is worse than showing it as missing.
  SplitTunnelSettings validated() =>
      SplitTunnelSettings.normalized(enabled: enabled, mode: mode, apps: apps);

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'mode': mode.name,
    'apps': [for (final app in apps) app.toJson()],
  };

  static SplitTunnelSettings fromJson(Object? value) {
    if (value is! Map) {
      return SplitTunnelSettings();
    }
    final enabled = value['enabled'] == true;
    final mode = SplitTunnelMode.values.firstWhere(
      (candidate) => candidate.name == value['mode'],
      orElse: () => SplitTunnelMode.include,
    );
    final rawApps = value['apps'];
    final apps = <SplitTunnelApp>[];
    if (rawApps is List) {
      for (final raw in rawApps) {
        final app = SplitTunnelApp.fromJson(raw);
        if (app != null && !apps.contains(app)) {
          apps.add(app);
        }
        if (apps.length >= maxApps) {
          break;
        }
      }
    }
    return SplitTunnelSettings.normalized(
      enabled: enabled,
      mode: mode,
      apps: apps,
    );
  }

  static List<SplitTunnelApp> _normalizeApps(List<SplitTunnelApp> apps) {
    final seen = <String>{};
    final result = <SplitTunnelApp>[];
    for (final app in apps) {
      if (!app.isValid || !seen.add(app.canonical)) {
        continue;
      }
      result.add(app);
      if (result.length >= maxApps) {
        break;
      }
    }
    return List.unmodifiable(result);
  }

  @override
  bool operator ==(Object other) {
    if (other is! SplitTunnelSettings ||
        other.enabled != enabled ||
        other.mode != mode ||
        other.apps.length != apps.length) {
      return false;
    }
    for (var i = 0; i < apps.length; i++) {
      if (other.apps[i] != apps[i]) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(enabled, mode, Object.hashAll(apps));

  @override
  String toString() =>
      'SplitTunnelSettings(enabled: $enabled, mode: ${mode.name}, '
      'apps: ${apps.length})';
}
