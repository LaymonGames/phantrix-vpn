import '../core/selection_reason.dart';
import '../model/vpn_server.dart';
import 'selection_mode.dart';
import 'server_scorer.dart';

/// A selection decision plus the reason, so the UI never guesses.
class Selection {
	const Selection({
		required this.server,
		required this.mode,
		required this.explanation,
		this.fellBack = false,
		this.fallbackCause,
	});

	final VpnServer server;
	final SelectionMode mode;

	/// What to tell the user. For example "Another server in the same country
	/// was used because the first one was unreachable."
	final String explanation;

	/// True when the requested target could not be served and this is the
	/// nearest acceptable substitute.
	final bool fellBack;

	/// Why a fallback happened. Null when it did not.
	final String? fallbackCause;

	SelectionReason get reason => switch (mode) {
		SelectionMode.fastest => SelectionReason.fastest,
		SelectionMode.nearest => SelectionReason.nearest,
		SelectionMode.random => SelectionReason.random,
		SelectionMode.recommended => SelectionReason.recommended,
		SelectionMode.healthiest => SelectionReason.healthiest,
		SelectionMode.favorite => SelectionReason.favorite,
		SelectionMode.recent => SelectionReason.recent,
		SelectionMode.manual => SelectionReason.manual,
		SelectionMode.specificServer => SelectionReason.specificServer,
	};
}

/// What the caller asked for.
class SelectionRequest {
	const SelectionRequest({
		this.mode = SelectionMode.recommended,
		this.countryCode,
		this.serverId,
		this.favorites = const [],
		this.recents = const [],
		this.seed,
		this.maxDistanceKm = 20000,
	});

	final SelectionMode mode;
	final String? countryCode;
	final String? serverId;

	/// Server ids the user pinned, in order.
	final List<String> favorites;

	/// Server ids used recently, most recent first.
	final List<String> recents;

	/// Random seed, so "random" is reproducible in tests.
	final int? seed;

	/// Servers further away than this are not considered.
	final double maxDistanceKm;
}

/// Chooses servers.
///
/// The rule the whole app follows: *never silently substitute*. If the user
/// asked for Japan and Japan is unavailable, the result says so explicitly
/// through [Selection.fellBack] and [Selection.explanation].
class ServerSelector {
	const ServerSelector({this.scorer = const ServerScorer()});

	final ServerScorer scorer;

	/// Ranks [servers] highest score first, dropping anything ineligible.
	List<ScoredServer> rank(List<VpnServer> servers, ScoreContext context) {
		final scored = <ScoredServer>[];
		for (final server in servers) {
			final result = scorer.scoreDetailed(server, context);
			if (result.score > 0) {
				scored.add(result);
			}
		}
		scored.sort((a, b) => b.score.compareTo(a.score));
		return scored;
	}

	/// Picks a server using [request].
	///
	/// Returns null only when nothing at all is eligible.
	Selection? select(
		List<VpnServer> servers,
		SelectionRequest request,
		ScoreContext context,
	) {
		final ranked = rank(servers, context);
		if (ranked.isEmpty) {
			return null;
		}
		final byId = <String, VpnServer>{
			for (final server in servers) server.id: server,
		};

		switch (request.mode) {
			case SelectionMode.specificServer:
				final id = request.serverId;
				if (id == null) {
					return null;
				}
				final match = byId[id];
				if (match == null) {
					return null;
				}
				return Selection(
					server: match,
					mode: SelectionMode.specificServer,
					explanation: 'You chose this server.',
				);

			case SelectionMode.random:
				final chosen = _random(ranked, request);
				return Selection(
					server: chosen.server,
					mode: SelectionMode.random,
					explanation: 'Chosen at random from the eligible servers.',
				);

			case SelectionMode.nearest:
				final nearest = _nearest(ranked, context);
				return Selection(
					server: nearest.server,
					mode: SelectionMode.nearest,
					explanation: 'The closest server that passed a health check.',
				);

			case SelectionMode.fastest:
				return Selection(
					server: ranked.first.server,
					mode: SelectionMode.fastest,
					explanation: 'The server with the best measured score right now.',
				);

			case SelectionMode.healthiest:
				final healthiest = _healthiest(ranked);
				return Selection(
					server: healthiest.server,
					mode: SelectionMode.healthiest,
					explanation: 'The server with the best recent connection record.',
				);

			case SelectionMode.recent:
				final recent = _firstMatching(request.recents, byId);
				return recent == null
						? null
						: Selection(
								server: recent,
								mode: SelectionMode.recent,
								explanation: 'A server you connected to recently.',
							);

			case SelectionMode.favorite:
				final favorite = _firstMatching(request.favorites, byId);
				return favorite == null
						? null
						: Selection(
								server: favorite,
								mode: SelectionMode.favorite,
								explanation: 'One of your pinned servers.',
							);

			case SelectionMode.manual:
			case SelectionMode.recommended:
				return Selection(
					server: ranked.first.server,
					mode: SelectionMode.recommended,
					explanation: _explainRecommended(ranked.first),
				);
		}
	}

	/// Picks within [countryCode], falling back outward when that country has
	/// nothing usable.
	///
	/// This is the path that must never lie: the returned [Selection] always
	/// says whether the user's country was honoured.
	Selection? selectForCountry(
		List<VpnServer> servers,
		String? countryCode,
		SelectionRequest request,
		ScoreContext context,
	) {
		if (countryCode == null || countryCode.isEmpty) {
			return select(servers, request, context);
		}

		final inCountry =
				servers.where((s) => s.countryCode == countryCode).toList(growable: false);
		final requestInCountry = SelectionRequest(
			mode: request.mode,
			countryCode: countryCode,
			serverId: request.serverId,
			favorites: request.favorites,
			recents: request.recents,
			seed: request.seed,
		);
		final local = select(inCountry, requestInCountry, context);
		if (local != null) {
			return local;
		}

		// The requested country has nothing usable.
		return _fallback(
			servers,
			request,
			context,
			cause: 'No usable server in $countryCode right now.',
		);
	}

	Selection? _fallback(
		List<VpnServer> servers,
		SelectionRequest request,
		ScoreContext context, {
		required String cause,
	}) {
		final ranked = rank(servers, context);
		if (ranked.isEmpty) {
			return null;
		}
		final chosen = ranked.first;
		return Selection(
			server: chosen.server,
			mode: SelectionMode.fastest,
			explanation:
				'$cause Connected to ${chosen.server.hostname} in ${chosen.server.countryCode} instead.',
			fellBack: true,
			fallbackCause: cause,
		);
	}

	static String _explainRecommended(ScoredServer scored) {
		final server = scored.server;
		final buffer = StringBuffer('Best balance of');
		final ms = server.metrics.latencyMs;
		if (ms != null) {
			buffer.write(' $ms ms latency');
		}
		final uptime = server.metrics.uptimeRatio;
		if (uptime != null) {
			buffer.write(', ${(uptime * 100).round()}% reported uptime');
		}
		final users = server.metrics.activeUsers;
		if (users != null) {
			buffer.write(', $users active users');
		}
		buffer.write('.');
		return buffer.toString();
	}

	static ScoredServer _random(List<ScoredServer> ranked, SelectionRequest request) {
		final seed = request.seed;
		if (seed == null) {
			return ranked.first;
		}
		final index = seed.abs() % ranked.length;
		return ranked[index];
	}

	static ScoredServer _nearest(List<ScoredServer> ranked, ScoreContext context) {
		final lat = context.userLatitude;
		final lon = context.userLongitude;
		if (lat == null || lon == null) {
			return ranked.first;
		}
		return ranked.reduce((a, b) {
			final aLat = a.server.latitude;
			final aLon = a.server.longitude;
			final bLat = b.server.latitude;
			final bLon = b.server.longitude;
			if (aLat == null || aLon == null) {
				return b;
			}
			if (bLat == null || bLon == null) {
				return a;
			}
			final aKm = ServerScorer.haversine(lat, lon, aLat, aLon);
			final bKm = ServerScorer.haversine(lat, lon, bLat, bLon);
			return aKm <= bKm ? a : b;
		});
	}

	static ScoredServer _healthiest(List<ScoredServer> ranked) => ranked.reduce((a, b) {
		final aNet = a.server.metrics.successCount - a.server.metrics.failureCount;
		final bNet = b.server.metrics.successCount - b.server.metrics.failureCount;
		return aNet >= bNet ? a : b;
	});

	static VpnServer? _firstMatching(
		List<String> ids,
		Map<String, VpnServer> byId,
	) {
		for (final id in ids) {
			final match = byId[id];
			if (match != null && ServerScorer.isEligible(match)) {
				return match;
			}
		}
		return null;
	}
}
