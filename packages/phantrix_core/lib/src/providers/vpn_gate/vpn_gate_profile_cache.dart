/// Persistence boundary for public VPN Gate client profiles.
///
/// A provider can use this cache after the feed becomes unreachable. Entries
/// are only candidates: every profile is decoded, parsed and security-validated
/// again by the provider before it can reach a tunnel engine.
abstract class VpnGateProfileCache {
  const VpnGateProfileCache();

  /// Returns server ID -> Base64 profile. Implementations must tolerate a
  /// missing or corrupt cache and return an empty map in that case.
  Map<String, String> read();

  /// Replaces the stored profile set with the latest successful feed.
  void write(Map<String, String> profiles);

  /// Deletes saved profiles.
  void clear();
}

/// Process-local implementation used by tests and non-persistent contexts.
class MemoryVpnGateProfileCache extends VpnGateProfileCache {
  MemoryVpnGateProfileCache();

  final Map<String, String> _profiles = {};

  @override
  Map<String, String> read() => Map.unmodifiable(_profiles);

  @override
  void write(Map<String, String> profiles) {
    _profiles
      ..clear()
      ..addAll(profiles);
  }

  @override
  void clear() => _profiles.clear();
}
