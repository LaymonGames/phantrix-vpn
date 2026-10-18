
class ServerMetrics {
  const ServerMetrics({
    this.latencyMs,
    this.handshakeMs,
    this.uptimeRatio,
    this.successCount = 0,
    this.failureCount = 0,
    this.activeUsers,
    this.downloadMbps,
    this.uploadMbps,
    this.lastMeasuredAt,
    this.score,
    this.consecutiveFailures = 0,
  });

  final int? latencyMs;
  final int? handshakeMs;
  final double? uptimeRatio;

  /// Local, device-side only: how often connecting to this server worked.
  final int successCount;
  final int failureCount;
  final int consecutiveFailures;

  final int? activeUsers;
  final double? downloadMbps;
  final double? uploadMbps;
  final DateTime? lastMeasuredAt;

  /// Provider-supplied aggregate score (VPN Gate uses one); null when the
  /// provider does not publish one.
  final int? score;

  static const ServerMetrics empty = ServerMetrics();

  bool get hasLatency => latencyMs != null;

  int? get timeSinceMeasurementSeconds {
    final at = lastMeasuredAt;
    if (at == null) {
      return null;
    }
    return DateTime.now().difference(at).inSeconds;
  }

  ServerMetrics copyWith({
    int? latencyMs,
    int? handshakeMs,
    double? uptimeRatio,
    int? successCount,
    int? failureCount,
    int? consecutiveFailures,
    int? activeUsers,
    double? downloadMbps,
    double? uploadMbps,
    DateTime? lastMeasuredAt,
    int? score,
  }) => ServerMetrics(
    latencyMs: latencyMs ?? this.latencyMs,
    handshakeMs: handshakeMs ?? this.handshakeMs,
    uptimeRatio: uptimeRatio ?? this.uptimeRatio,
    successCount: successCount ?? this.successCount,
    failureCount: failureCount ?? this.failureCount,
    consecutiveFailures: consecutiveFailures ?? this.consecutiveFailures,
    activeUsers: activeUsers ?? this.activeUsers,
    downloadMbps: downloadMbps ?? this.downloadMbps,
    uploadMbps: uploadMbps ?? this.uploadMbps,
    lastMeasuredAt: lastMeasuredAt ?? this.lastMeasuredAt,
    score: score ?? this.score,
  );

  static ServerMetrics recordSuccess(
    ServerMetrics base, {
    int? latencyMs,
    int? handshakeMs,
  }) => base.copyWith(
    successCount: base.successCount + 1,
    consecutiveFailures: 0,
    latencyMs: latencyMs ?? base.latencyMs,
    handshakeMs: handshakeMs ?? base.handshakeMs,
    lastMeasuredAt: DateTime.now(),
  );

  static ServerMetrics recordFailure(ServerMetrics base) => base.copyWith(
    failureCount: base.failureCount + 1,
    consecutiveFailures: base.consecutiveFailures + 1,
    lastMeasuredAt: DateTime.now(),
  );
}
