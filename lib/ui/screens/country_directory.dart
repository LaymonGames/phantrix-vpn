import 'package:phantrix_core/phantrix_core.dart';

import '../widgets/globe_map.dart';

/// One country row, derived from real server data.
///
/// Every field here comes from a [DirectorySnapshot]. Nothing is defaulted to
/// a plausible-looking number: an unmeasured latency is null and is rendered
/// as a dash.
class CountryEntry {
  CountryEntry({
    required this.code,
    required this.servers,
    required this.bestLatencyMs,
    required this.protocols,
    required this.trust,
  });

  /// ISO 3166-1 alpha-2, upper case.
  final String code;

  /// Every server currently held for this country, including unreachable
  /// ones. The UI says how many of them are usable rather than implying the
  /// whole set will work.
  final List<VpnServer> servers;

  /// The best latency among servers that actually reported one, or null when
  /// none did.
  final int? bestLatencyMs;

  /// The protocols available here.
  final Set<ProtocolKind> protocols;

  /// The weakest trust level present, so a public relay is never presented
  /// with the same badge as a project-operated server.
  final TrustLevel trust;

  int get serverCount => servers.length;

  int get usableCount => servers.where((s) => s.status.isUsable).length;

  /// The country name in [languageCode], falling back to the code.
  String nameFor(String languageCode) {
    final name = GeoDatabase.nameOf(code, languageCode);
    return name.isEmpty ? code : name;
  }

  String get flag => GeoDatabase.flagOf(code);
}

/// Builds country rows from a directory snapshot.
///
/// Kept as a pure function so it can be tested without a widget tree, and so
/// the "one country per real server" rule has a single definition.
List<CountryEntry> buildCountryEntries(DirectorySnapshot snapshot) {
  final entries = <CountryEntry>[];
  for (final group in snapshot.byCountry.entries) {
    if (group.value.isEmpty) {
      continue;
    }
    final code = group.key.toUpperCase();

    // Only latencies that were actually measured count. A null in the
    // list must not become 0, which would sort to the top.
    final measured = group.value
        .where((s) => s.metrics.latencyMs != null)
        .map((s) => s.metrics.latencyMs!)
        .toList(growable: false);
    measured.sort();

    entries.add(
      CountryEntry(
        code: code,
        servers: List.unmodifiable(group.value),
        bestLatencyMs: measured.isEmpty ? null : measured.first,
        protocols: Set.unmodifiable(group.value.map((s) => s.protocol)),
        trust: weakestTrust(group.value.map((s) => s.trustLevel)),
      ),
    );
  }
  return entries;
}

TrustLevel weakestTrust(Iterable<TrustLevel> levels) {
  // publicRelay is the weakest value the enum can hold for our purposes;
  // start at the strongest so the weakest wins regardless of declaration order.
  var weakest = TrustLevel.projectVerified;
  for (final level in levels) {
    if (level.index > weakest.index) {
      weakest = level;
    }
  }
  return weakest;
}

/// Converts servers into map pins.
///
/// A server with no coordinates is dropped rather than pinned at (0, 0),
/// which would place it off the coast of Africa and be actively misleading.
List<MapServer> mapServersOf(List<VpnServer> servers) => [
  for (final server in servers)
    if (server.latitude != null && server.longitude != null)
      MapServer(
        latitude: server.latitude!,
        longitude: server.longitude!,
        label: server.city ?? server.countryCode,
        countryCode: server.countryCode,
      ),
];

/// Sorts country rows for display.
List<CountryEntry> sortCountryEntries(List<CountryEntry> entries, String mode) {
  final sorted = List<CountryEntry>.of(entries);
  switch (mode) {
    case 'name':
      sorted.sort((a, b) => a.nameFor('en').compareTo(b.nameFor('en')));
    case 'count':
      sorted.sort((a, b) => b.serverCount.compareTo(a.serverCount));
    default:
      // Unmeasured countries sort last rather than pretending to be fast.
      sorted.sort((a, b) {
        final la = a.bestLatencyMs;
        final lb = b.bestLatencyMs;
        if (la == null && lb == null) {
          return a.nameFor('en').compareTo(b.nameFor('en'));
        }
        if (la == null) {
          return 1;
        }
        if (lb == null) {
          return -1;
        }
        return la.compareTo(lb);
      });
  }
  return sorted;
}
