/// An executable the platform found, or one the user picked.
///
/// The icon is not part of discovery: enumerating several hundred Start Menu
/// shortcuts and extracting every icon would make the split-tunnel screen wait
/// on work it does not need yet. The list renders names and paths first, and
/// asks for an icon per visible row through `PhantrixPlatform.appIcon`.
class InstalledApp {
  const InstalledApp({required this.name, required this.path, this.iconPng});

  /// The label the shell shows for this application.
  final String name;

  /// The executable's absolute Windows path.
  final String path;

  /// A PNG-encoded icon as base64, when the platform could extract one.
  ///
  /// Kept as a string because that is what crosses the method channel. The UI
  /// decodes it once and caches the bytes.
  final String? iconPng;

  bool get hasIcon => iconPng != null && iconPng!.isNotEmpty;

  @override
  bool operator ==(Object other) =>
      other is InstalledApp && other.path.toLowerCase() == path.toLowerCase();

  @override
  int get hashCode => path.toLowerCase().hashCode;

  @override
  String toString() => 'InstalledApp($name, $path)';
}
