import 'package:phantrix_core/phantrix_core.dart';

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

  /// The states this country has servers in, fastest first. Servers whose
  /// provider published no state are not listed here; they still count
  /// toward "fastest".
  List<StateEntry> get states {
    final byState = <String, List<VpnServer>>{};
    for (final server in servers) {
      final state = server.subdivision;
      if (state != null) {
        byState.putIfAbsent(state, () => <VpnServer>[]).add(server);
      }
    }
    final entries = [
      for (final e in byState.entries)
        StateEntry(name: e.key, servers: List.unmodifiable(e.value)),
    ];
    entries.sort((a, b) {
      final la = a.bestLatencyMs;
      final lb = b.bestLatencyMs;
      if (la == null && lb == null) {
        return a.name.compareTo(b.name);
      }
      if (la == null) {
        return 1;
      }
      if (lb == null) {
        return -1;
      }
      return la.compareTo(lb);
    });
    return entries;
  }
}

/// One state inside a country, derived from real server data.
class StateEntry {
  StateEntry({required this.name, required this.servers});

  final String name;
  final List<VpnServer> servers;

  int get serverCount => servers.length;

  int? get bestLatencyMs {
    final measured = servers
        .map((s) => s.metrics.latencyMs)
        .whereType<int>()
        .toList(growable: false);
    if (measured.isEmpty) {
      return null;
    }
    return measured.reduce((a, b) => a < b ? a : b);
  }
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
    // ZZ is the placeholder for a server with no known country; it is not a
    // place a user can choose.
    if (code == 'ZZ') {
      continue;
    }

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
