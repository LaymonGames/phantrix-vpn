import '../protocol/protocol_kind.dart';
import 'logging_policy.dart';
import 'server_status.dart';
import 'trust_level.dart';

/// Measured quality of a server. Every field is a real observation or null;
/// there is no default "score" that pretends a server was measured.
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
	}) =>
			ServerMetrics(
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

	static ServerMetrics recordSuccess(ServerMetrics base, {int? latencyMs, int? handshakeMs}) =>
			base.copyWith(
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

/// A single VPN server the app can connect to.
///
/// Immutable. Re-fetched lists replace instances wholesale so a partially
/// updated server can never be shown.
class VpnServer {
	const VpnServer({
		required this.id,
		required this.hostname,
		required this.hostAddress,
		required this.port,
		required this.protocol,
		required this.trustLevel,
		required this.countryCode,
		required this.providerId,
		this.city,
		this.region,
		this.latitude,
		this.longitude,
		this.status = ServerStatus.unknown,
		this.loggingPolicy = LoggingPolicy.unknown,
		this.operatorName,
		this.metrics = ServerMetrics.empty,
		this.firstSeenAt,
		this.lastSeenAt,
		this.requiresCredentials = false,
		this.fingerprint,
		this.notes = const [],
	});

	/// Stable identity within a provider. Not globally unique.
	final String id;
	final String hostname;

	/// Resolved endpoint IP, when the provider publishes one.
	final String? hostAddress;
	final int? port;
	final ProtocolKind protocol;
	final TrustLevel trustLevel;
	final ServerStatus status;
	final String countryCode;
	final String providerId;
	final String? city;
	final String? region;
	final double? latitude;
	final double? longitude;
	final LoggingPolicy loggingPolicy;
	final String? operatorName;
	final ServerMetrics metrics;
	final DateTime? firstSeenAt;
	final DateTime? lastSeenAt;
	final bool requiresCredentials;

	/// Non-secret configuration fingerprint, used for duplicate detection.
	final String? fingerprint;
	final List<String> notes;

	bool get isUsable => status.isUsable && !requiresCredentials;

	/// Age of the provider's information, or null when unknown.
	Duration? get informationAge {
		final seen = lastSeenAt;
		if (seen == null) {
			return null;
		}
		return DateTime.now().difference(seen);
	}

	/// Country name in ISO 3166-1 alpha-2 form when the code is not known.
	String get countryName => countryCode;

	String get locationLabel {
		final city = this.city;
		final country = countryName;
		if (city == null || city.isEmpty) {
			return country;
		}
		return '$city, $country';
	}

	VpnServer copyWith({
		String? id,
		String? hostname,
		String? hostAddress,
		int? port,
		ProtocolKind? protocol,
		TrustLevel? trustLevel,
		ServerStatus? status,
		String? countryCode,
		String? providerId,
		String? city,
		String? region,
		double? latitude,
		double? longitude,
		LoggingPolicy? loggingPolicy,
		String? operatorName,
		ServerMetrics? metrics,
		DateTime? firstSeenAt,
		DateTime? lastSeenAt,
		bool? requiresCredentials,
		String? fingerprint,
		List<String>? notes,
	}) =>
			VpnServer(
				id: id ?? this.id,
				hostname: hostname ?? this.hostname,
				hostAddress: hostAddress ?? this.hostAddress,
				port: port ?? this.port,
				protocol: protocol ?? this.protocol,
				trustLevel: trustLevel ?? this.trustLevel,
				status: status ?? this.status,
				countryCode: countryCode ?? this.countryCode,
				providerId: providerId ?? this.providerId,
				city: city ?? this.city,
				region: region ?? this.region,
				latitude: latitude ?? this.latitude,
				longitude: longitude ?? this.longitude,
				loggingPolicy: loggingPolicy ?? this.loggingPolicy,
				operatorName: operatorName ?? this.operatorName,
				metrics: metrics ?? this.metrics,
				firstSeenAt: firstSeenAt ?? this.firstSeenAt,
				lastSeenAt: lastSeenAt ?? this.lastSeenAt,
				requiresCredentials: requiresCredentials ?? this.requiresCredentials,
				fingerprint: fingerprint ?? this.fingerprint,
				notes: notes ?? this.notes,
			);

	@override
	bool operator ==(Object other) =>
			other is VpnServer && other.id == id && other.providerId == providerId;

	@override
	int get hashCode => Object.hash(id, providerId);
}
