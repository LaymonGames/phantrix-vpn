import 'dart:math' as math;

import '../model/trust_level.dart';
import '../model/vpn_server.dart';

/// How much each signal contributes to the fast-server score.
///
/// These are opinionated defaults; the weights are injectable so they can be
/// tuned from tests and settings without editing this file.
class ScoreWeights {
	const ScoreWeights({
		this.latency = 1.0,
		this.reliability = 1.4,
		this.uptime = 0.8,
		this.load = 0.7,
		this.distance = 0.35,
		this.history = 0.6,
		this.trust = 0.3,
	});

	/// Weight for the round-trip time measured by this device.
	final double latency;

	/// Weight for the local success/failure record.
	final double reliability;

	/// Weight for the provider-reported uptime.
	final double uptime;

	/// Weight for the reported number of active users.
	final double load;

	/// Weight for geographic distance. Deliberately low: distance alone is a
	/// poor predictor of what a user actually experiences.
	final double distance;

	/// Weight for the recent score history, to damp oscillation.
	final double history;

	/// Weight for the trust label. Low, because it must never be the primary
	/// reason a server is chosen or rejected.
	final double trust;

	/// The sum of every weight, used to turn the weighted sum into a mean.
	double get totalWeight =>
			latency + reliability + uptime + load + distance + history + trust;

	static const ScoreWeights defaults = ScoreWeights();
}

/// Extra context the scorer needs that is not part of a server.
class ScoreContext {
	const ScoreContext({
		this.userLatitude,
		this.userLongitude,
		this.scoreHistory = const {},
	});

	final double? userLatitude;
	final double? userLongitude;

	/// Recent per-server scores, used to damp oscillation.
	final Map<String, double> scoreHistory;
}

/// A scored server.
class ScoredServer {
	const ScoredServer({
		required this.server,
		required this.score,
		required this.partials,
	});

	final VpnServer server;

	/// Higher is better. 0 means "not eligible".
	final double score;

	/// The individual contributions, for the "why this server" UI.
	final Map<String, double> partials;
}

/// Ranks servers.
///
/// The function is pure and total: every input produces a score, and an
/// ineligible server always scores 0 rather than being dropped silently, so
/// the UI can explain why a server was not chosen.
class ServerScorer {
	const ServerScorer({this.weights = ScoreWeights.defaults});

	final ScoreWeights weights;

	/// The number of consecutive failures after which a server is skipped.
	static const int maxConsecutiveFailures = 3;

	/// Latency (ms) at which a server scores zero.
	static const double unusableLatencyMs = 900;

	/// Users at which a relay is considered saturated.
	static const double saturatingUsers = 300;

	/// Distance (km) at which a server scores zero.
	static const double unusableDistanceKm = 20000;

	/// Scores one server. Returns 0 when the server is not eligible.
	double score(VpnServer server, ScoreContext context) =>
			scoreDetailed(server, context).score;

	ScoredServer scoreDetailed(VpnServer server, ScoreContext context) {
		final partials = <String, double>{};
		if (!isEligible(server)) {
			return ScoredServer(server: server, score: 0, partials: partials);
		}

		final latencyScore = _latencyScore(server);
		final reliabilityScore = _reliabilityScore(server);
		final uptimeScore = _uptimeScore(server);
		final loadScore = _loadScore(server);
		final distanceScore = _distanceScore(server, context);
		final historyScore = _historyScore(server, context);
		final trustScore = _trustScore(server);

		partials['latency'] = latencyScore;
		partials['reliability'] = reliabilityScore;
		partials['uptime'] = uptimeScore;
		partials['load'] = loadScore;
		partials['distance'] = distanceScore;
		partials['history'] = historyScore;
		partials['trust'] = trustScore;

		// A weighted mean, not a sum, so a perfect server is exactly 100 and a
		// terrible one is exactly 0 regardless of the weights. Without this the
		// number is not comparable between weight profiles.
		final totalWeight = weights.totalWeight;
		final weighted = latencyScore * weights.latency +
				reliabilityScore * weights.reliability +
				uptimeScore * weights.uptime +
				loadScore * weights.load +
				distanceScore * weights.distance +
				historyScore * weights.history +
				trustScore * weights.trust;

		return ScoredServer(
			server: server,
			score: totalWeight <= 0 ? 0 : _clamp(weighted / totalWeight, 0, 100),
			partials: partials,
		);
	}

	/// Hard eligibility rules. These are about being usable at all, not about
	/// quality, so they gate the score rather than lowering it.
	static bool isEligible(VpnServer server) {
		if (!server.status.isUsable) {
			return false;
		}
		// A server we cannot authenticate to is not eligible, but the user can
		// still pick it explicitly and be told why.
		if (server.requiresCredentials) {
			return false;
		}
		if (server.metrics.consecutiveFailures >= maxConsecutiveFailures) {
			return false;
		}
		return true;
	}

	/// 100 when unmeasurably good, 0 when unusable.
	double _latencyScore(VpnServer server) {
		final ms = server.metrics.latencyMs;
		if (ms == null || ms <= 0) {
			return _unknownLatencyScore;
		}
		if (ms >= unusableLatencyMs) {
			return 0;
		}
		return _clamp(1 - (ms / unusableLatencyMs), 0, 1) * 100;
	}

	static const double _unknownLatencyScore = 35;

	double _reliabilityScore(VpnServer server) {
		final attempts = server.metrics.successCount + server.metrics.failureCount;
		if (attempts < 2) {
			return 50;
		}
		final ratio = server.metrics.successCount / attempts;
		return _clamp(ratio, 0, 1) * 100;
	}

	double _uptimeScore(VpnServer server) {
		final uptime = server.metrics.uptimeRatio;
		if (uptime == null) {
			return 50;
		}
		return _clamp(uptime, 0, 1) * 100;
	}

	double _loadScore(VpnServer server) {
		final users = server.metrics.activeUsers;
		if (users == null || users < 0) {
			return 50;
		}
		if (users >= saturatingUsers) {
			return 0;
		}
		return _clamp(1 - (users / saturatingUsers), 0, 1) * 100;
	}

	double _distanceScore(VpnServer server, ScoreContext context) {
		final lat = context.userLatitude;
		final lon = context.userLongitude;
		final serverLat = server.latitude;
		final serverLon = server.longitude;
		if (lat == null || lon == null || serverLat == null || serverLon == null) {
			return 50;
		}
		final km = haversine(lat, lon, serverLat, serverLon);
		if (km >= unusableDistanceKm) {
			return 0;
		}
		return _clamp(1 - (km / unusableDistanceKm), 0, 1) * 100;
	}

	double _historyScore(VpnServer server, ScoreContext context) {
		final previous = context.scoreHistory[server.id];
		if (previous == null) {
			return 50;
		}
		return _clamp(previous, 0, 100);
	}

	double _trustScore(VpnServer server) => switch (server.trustLevel) {
		TrustLevel.projectVerified => 100,
		TrustLevel.community => 70,
		TrustLevel.publicRelay => 30,
		TrustLevel.imported => 30,
		TrustLevel.unknown => 20,
	};

	static double _clamp(double value, double min, double max) =>
			value < min ? min : (value > max ? max : value);

	/// Great-circle distance in kilometres. Exposed for the selector.
	/// Great-circle distance in kilometres. Used by the selector.
	static double haversine(double lat1, double lon1, double lat2, double lon2) {
		const earthRadiusKm = 6371.0;
		final dLat = _rad(lat2 - lat1);
		final dLon = _rad(lon2 - lon1);
		final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
				math.cos(_rad(lat1)) *
					math.cos(_rad(lat2)) *
					math.sin(dLon / 2) *
					math.sin(dLon / 2);
		return 2 * earthRadiusKm * math.atan2(math.sqrt(a), math.sqrt(1 - a));
	}

	static double _rad(double d) => d * math.pi / 180;
}
