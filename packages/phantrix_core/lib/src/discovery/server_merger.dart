import '../model/logging_policy.dart';
import '../model/server_status.dart';
import '../model/vpn_server.dart';

/// De-duplicates and merges server lists.
///
/// Two rows that share an endpoint are the same server, whatever the provider
/// calls them. The one with the most complete metadata wins, but never the one
/// that claims a better score: the whole point is that we do not trust any
/// single provider.
class ServerMerger {
  const ServerMerger._();

  /// The key that identifies the same physical server.
  static String key(VpnServer server) {
    final address = server.hostAddress ?? server.hostname;
    final port = server.port;
    return '${server.protocol.shortLabel}|$address|$port';
  }

  /// Merges [fresh] with [previous] for one provider.
  ///
  /// Entries in [previous] that belong to other providers are kept, so a
  /// single provider outage does not empty the list. Entries in [previous]
  /// that belong to [providerId] are replaced.
  static List<VpnServer> merge(
    List<VpnServer> fresh, {
    required List<VpnServer> previous,
    required String providerId,
  }) {
    final byKey = <String, VpnServer>{};

    for (final server in previous) {
      if (server.providerId == providerId) {
        continue;
      }
      byKey[key(server)] = server;
    }

    for (final server in fresh) {
      final existing = byKey[key(server)];
      byKey[key(server)] = existing == null
          ? server
          : combine(existing, server);
    }

    return byKey.values.toList(growable: false);
  }

  /// Field-by-field merge that never downgrades to a value already known.
  static VpnServer combine(VpnServer base, VpnServer overlay) {
    if (_completeness(overlay) < _completeness(base)) {
      return combine(overlay, base);
    }
    return base.copyWith(
      metrics: base.metrics.hasLatency ? base.metrics : overlay.metrics,
      status:
          base.status == ServerStatus.unknown &&
              overlay.status != ServerStatus.unknown
          ? overlay.status
          : base.status,
      hostAddress: base.hostAddress ?? overlay.hostAddress,
      port: base.port ?? overlay.port,
      city: base.city ?? overlay.city,
      latitude: base.latitude ?? overlay.latitude,
      longitude: base.longitude ?? overlay.longitude,
      operatorName: base.operatorName ?? overlay.operatorName,
      lastSeenAt: overlay.lastSeenAt,
      firstSeenAt: base.firstSeenAt,
      loggingPolicy: base.loggingPolicy == LoggingPolicy.unknown
          ? overlay.loggingPolicy
          : base.loggingPolicy,
      notes: base.notes.length >= overlay.notes.length
          ? base.notes
          : overlay.notes,
    );
  }

  static int _completeness(VpnServer server) {
    var score = 0;
    if (server.hostAddress != null) {
      score += 2;
    }
    if (server.city != null) {
      score += 2;
    }
    if (server.metrics.hasLatency) {
      score += 3;
    }
    if (server.loggingPolicy != LoggingPolicy.unknown) {
      score += 1;
    }
    if (server.operatorName != null) {
      score += 1;
    }
    if (server.status != ServerStatus.unknown) {
      score += 1;
    }
    return score;
  }
}
