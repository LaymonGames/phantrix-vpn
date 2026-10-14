import 'dart:io';

import 'package:phantrix_core/phantrix_core.dart';
import 'package:phantrix_platform/phantrix_platform.dart';

import '../discovery/discovery_controller.dart';
import 'connection_controller.dart';

/// A server that was chosen, plus the configuration that can actually be
/// used to reach it.
///
/// The pair travels together because the second half is not implied by the
/// first: a provider can publish metadata for a server and still be unable
/// to hand over a working configuration. Connecting with a server and no
/// config is exactly the bug this type makes impossible.
class ResolvedTarget {
	const ResolvedTarget({
		required this.server,
		required this.config,
		required this.selection,
		required this.provider,
	});

	final VpnServer server;

	/// Already parsed and security-validated by the provider.
	final VpnConfiguration config;

	/// Why this server, including whether the request was honoured.
	final Selection selection;

	/// The source the configuration came from.
	final ServerProvider provider;

	bool get fellBack => selection.fellBack;

	/// A line the UI can show verbatim. Never says "connected" — nothing has
	/// been connected at this point.
	String get explanation => selection.explanation;
}

/// Why a connection could not even be attempted.
///
/// These are distinct cases because each one needs a different action from the
/// user, and collapsing them into "connection failed" is what makes a VPN app
/// frustrating.
enum ResolveFailure {
	/// The directory has never been loaded, or the last refresh found nothing.
	noServers,

	/// A country was asked for but the list has no entry for it at all.
	unknownCountry,

	/// The country has servers but none passed the health and trust rules.
	noEligibleServer,

	/// A server was chosen but the provider that published it is gone.
	providerUnavailable,

	/// The provider declined to hand over a configuration for this server.
	/// This is a normal outcome for a metadata-only source, not a bug.
	noConfiguration,

	/// Fetching the configuration failed.
	fetchFailed,
}

/// The outcome of a resolve attempt.
sealed class ResolveResult {
	const ResolveResult();
}

/// A server and configuration are ready to hand to the tunnel.
class ResolveSuccess extends ResolveResult {
	const ResolveSuccess(this.target, {this.notice});

	final ResolvedTarget target;

	/// Set when the request was substituted — for example the chosen country
	/// had nothing usable and another was used. The UI must show this; a
	/// silent substitution is the failure mode this whole class exists to
	/// prevent.
	final String? notice;
}

/// No connection could be attempted. [message] is safe to show a user.
class ResolveFailureResult extends ResolveResult {
	const ResolveFailureResult(this.reason, this.message);

	final ResolveFailure reason;
	final String message;
}

/// Answers whether a relay's TCP port accepts a connection at all.
///
/// Injected so tests never open a socket; the app passes [tcpRelayProbe].
typedef RelayProbe = Future<bool> Function(
	String host,
	int port,
	Duration timeout,
);

/// A real TCP connect, closed immediately.
///
/// This is the cheapest honest question there is about a TCP relay: does
/// anything answer on that port? Volunteer relay lists are full of entries
/// that do not, and finding that out here costs a few seconds where handing
/// the relay to the engine costs a whole attempt budget. Only a failed connect
/// or a timeout counts as "no"; it says nothing about whether the relay would
/// complete a TLS handshake, so a "yes" is a reason to try it, not a promise.
Future<bool> tcpRelayProbe(String host, int port, Duration timeout) async {
	try {
		final socket = await Socket.connect(host, port, timeout: timeout);
		socket.destroy();
		return true;
	} on Object {
		return false;
	}
}

/// Turns "connect me to Japan" into a specific server and its configuration.
///
/// Responsibilities kept out of both the UI and [ConnectionController]:
///
///  * run [ServerSelector] over the live directory, honouring the requested
///    country and reporting any substitution;
///  * fetch the chosen server's configuration from the provider that
///    published it;
///  * distinguish "nothing to connect to" from "could not fetch", because
///    the user's next action differs.
///
/// What it deliberately does **not** do: invent coordinates for
/// [SelectionMode.nearest]. This build requests no location permission, so a
/// user's position is unknown and the selector falls back to score order. The
/// UI must not describe that as "nearest".
class ConnectionResolver {
	ConnectionResolver({
		required this.discovery,
		this.selector = const ServerSelector(),
		this.userLatitude,
		this.userLongitude,
		this.walkDepth = defaultWalkDepth,
		this.walkStepTimeout = defaultWalkStepTimeout,
		this.relayProbe,
		this.probeTimeout = defaultProbeTimeout,
	});

	/// The live directory this resolver selects from.
	final DiscoveryController discovery;

	/// The scoring policy. Injectable so a test can pin the weights.
	final ServerSelector selector;

	/// Null unless the user has actually granted location access. Left null in
	/// this build: no location permission is requested anywhere.
	final double? userLatitude;
	final double? userLongitude;

	/// How many servers one automatic attempt may try, in rank order.
	final int walkDepth;

	/// How long each server of a walk gets before the attempt moves on.
	///
	/// Shorter than a single explicit attempt on purpose: a live relay
	/// answers a handshake in seconds, and a silent one must not spend the
	/// budget of every server ranked behind it.
	final Duration walkStepTimeout;

	/// Reachability check run on TCP relays before an automatic attempt.
	///
	/// Null (the default) disables probing, which is what tests want. When set,
	/// an automatic walk first checks the top [probeWindow] candidates in
	/// parallel and tries the ones that answered before the ones that did not,
	/// so a dead relay costs [probeTimeout] once, in parallel, rather than a
	/// full [walkStepTimeout] each, one after another.
	final RelayProbe? relayProbe;

	/// How long one reachability probe may take.
	final Duration probeTimeout;

	/// How many ranked candidates are probed together.
	static const int probeWindow = 10;

	/// The default for [probeTimeout].
	static const Duration defaultProbeTimeout = Duration(seconds: 3);

	/// The default for [walkDepth].
	static const int defaultWalkDepth = 6;

	/// The default for [walkStepTimeout].
	///
	/// Generous next to the handshakes measured against live volunteer
	/// relays — a few seconds — because a step that cuts a *slow but real*
	/// server short would trade a certain failure for an unlucky one.
	static const Duration defaultWalkStepTimeout = Duration(seconds: 20);

	/// True when [SelectionMode.nearest] would be a lie, because the user's
	/// position is not known.
	bool get canMeasureDistance => userLatitude != null && userLongitude != null;

	ScoreContext get _scoreContext => ScoreContext(
		userLatitude: userLatitude,
		userLongitude: userLongitude,
	);

	/// The servers currently eligible to be chosen from, best first.
	///
	/// Exposed so the UI can show the ranked list without re-running selection.
	List<ScoredServer> ranked() => selector.rank(discovery.snapshot.servers, _scoreContext);

	/// Whether this build can start a tunnel for [kind] right now.
	///
	/// WireGuard is always available; OpenVPN depends on the engine being
	/// bundled for the running platform, which the native side reports. A
	/// null [capabilities] means the platform has not said — treated as "not
	/// available", because starting a tunnel that cannot be started is worse
	/// than declining it.
	static bool _supports(ProtocolKind kind, PlatformCapabilities? capabilities) =>
			switch (kind) {
				ProtocolKind.wireGuard => true,
				ProtocolKind.openVpn => capabilities?.openVpn ?? false,
			};

	/// What to tell the user when [kind] is not supported here.
	///
	/// Written for the person reading it: names the protocol, says plainly
	/// that nothing was attempted, and offers the two things that would
	/// actually work. Never "connection failed" — nothing was connected.
	static String _protocolRejection(ProtocolKind kind) => switch (kind) {
		ProtocolKind.openVpn =>
			'This server speaks OpenVPN, which this build cannot start on this '
				'device, so nothing was attempted. Choose a server that offers '
				'WireGuard, or import a WireGuard .conf file.',
		// Unreachable today: WireGuard is always supported. Kept so that
		// adding a protocol without adding its availability check becomes a
		// compile error here rather than a silent fall-through.
		ProtocolKind.wireGuard =>
			'This server speaks WireGuard, which is not available on this device.',
	};

	/// Resolves [request] into a usable target.
	///
	/// [capabilities] is what the running platform can actually start. Left
	/// null, the answer is the conservative one: WireGuard only. A server is
	/// never fetched, let alone dialled, for a protocol this build cannot run
	/// — the rejection happens here, with a message that names the protocol
	/// and what the user can do instead, rather than as a tunnel that starts
	/// and then fails for an unexplained reason.
	Future<ResolveResult> resolve(
		SelectionRequest request, {
		PlatformCapabilities? capabilities,
	}) async {
		final snapshot = discovery.snapshot;
		final servers = snapshot.servers;
		if (servers.isEmpty) {
			return const ResolveFailureResult(
				ResolveFailure.noServers,
				'No server endpoints or saved profiles are available yet. The app can '
					'try cached relays when present, or connect using an imported VPN configuration.',
			);
		}

		final country = request.countryCode;
		if (country != null && country.isNotEmpty) {
			final known = servers.any((s) => s.countryCode == country.toUpperCase());
			if (!known) {
				return ResolveFailureResult(
					ResolveFailure.unknownCountry,
					'The server list has no servers in $country.',
				);
			}
		}

		final selectionPool = _poolForSelection(servers);
		final rankedSelection = selector.selectForCountry(
			selectionPool,
			country,
			request,
			_scoreContext,
		);
		final selection = rankedSelection == null
				? null
				: _restoreOriginalSelection(rankedSelection, servers);
		if (selection == null) {
			// Servers exist, the country is real, but nothing passed the
			// eligibility rules. That is a different problem from an empty
			// list and deserves its own message.
			return country == null || country.isEmpty
					? const ResolveFailureResult(
							ResolveFailure.noEligibleServer,
							'No server currently passes the health and trust checks. '
								'Try again shortly.',
						)
					: ResolveFailureResult(
							ResolveFailure.noEligibleServer,
							'No server in $country currently passes the health and trust checks.',
						);
		}

		final server = selection.server;
		if (!_supports(server.protocol, capabilities)) {
			return ResolveFailureResult(
				ResolveFailure.noConfiguration,
				_protocolRejection(server.protocol),
			);
		}
		final provider = discovery.providerFor(server);
		if (provider == null) {
			return ResolveFailureResult(
				ResolveFailure.providerUnavailable,
				'The source "${server.providerId}" that published '
					'${server.hostname} is no longer enabled. Refresh the server list.',
			);
		}

		ProviderConfig? fetched;
		String? fetchFailure;
		try {
			fetched = await provider.fetchConfig(server.id);
		} on AppError catch (error) {
			fetched = null;
			fetchFailure = error.message;
		} catch (error) {
			fetched = null;
			// The provider contract says return a failure rather than throw.
			// If one throws anyway the connection must still fail cleanly
			// rather than escaping as an unhandled error.
			fetchFailure = 'Could not download the configuration for ${server.hostname}.';
		}

		if (fetched == null || !_supports(fetched.validated.kind, capabilities)) {
			// VPN Gate's large catalog is published before every embedded
			// profile is decoded and checked. If this automatic choice has an
			// invalid/unavailable profile, try the next few ranked candidates
			// instead of making the user wait for discovery only to fail here.
			if (_walks(request)) {
				final alternate = await _resolveProfileFallback(
					request: request,
					excludedServerId: server.id,
					capabilities: capabilities,
				);
				if (alternate != null) {
					return ResolveSuccess(alternate, notice: alternate.selection.explanation);
				}
			}

			if (fetchFailure != null) {
				return ResolveFailureResult(ResolveFailure.fetchFailed, fetchFailure);
			}
			if (fetched == null) {
				return ResolveFailureResult(
					ResolveFailure.noConfiguration,
					'${provider.label} lists ${server.hostname} but its profile is missing '
						'or failed validation, so it cannot be connected to.',
				);
			}
			return ResolveFailureResult(
				ResolveFailure.noConfiguration,
				'${provider.label} lists ${server.hostname} but supplies only '
					'a ${fetched.validated.kind.label} configuration, which this '
					'build cannot start on this device, so it cannot be connected to.',
			);
		}

		return ResolveSuccess(
			ResolvedTarget(
				server: server,
				config: fetched.validated,
				selection: selection,
				provider: provider,
			),
			notice: selection.fellBack ? selection.explanation : null,
		);
	}

	/// Resolves and connects, walking down the ranking when a server is
	/// silent.
	///
	/// The ranking predicts quality from measurements taken *elsewhere* —
	/// the provider's ping column, its uptime — so the top-ranked server can
	/// be a black hole from this network. For an automatic request that is
	/// worth [walkStepTimeout] rather than the whole attempt: the next
	/// eligible server is already known, and a silent one carries no
	/// diagnosis that would apply to it too.
	///
	/// A request that names a server — explicitly, as a favourite, or
	/// through a recent one — is never walked: the user asked for *that*
	/// server, and substituting another one silently is exactly the lie the
	/// selection rules forbid.
	///
	/// The platform capabilities come from [ConnectionController], so the
	/// protocol check and the tunnel that follows it are decided by the same
	/// fact rather than by two independent guesses.
	Future<ResolveResult> resolveAndConnect(
		SelectionRequest request, {
		required ConnectionController connection,
	}) async {
		final result = await resolve(
			request,
			capabilities: connection.capabilities,
		);
		if (result is ResolveFailureResult) {
			connection.reportSelectionFailure(result.message);
			return result;
		}
		final success = result as ResolveSuccess;

		if (!_walks(request)) {
			await connection.connect(
				server: success.target.server,
				config: success.target.config,
				countryLabel: success.target.server.countryCode,
			);
			return success;
		}

		var target = success.target;
		var alternates = _alternates(request, success, connection.capabilities);
		final resolved = <String, ResolvedTarget>{target.server.id: target};
		if (relayProbe != null && alternates.isNotEmpty) {
			// Dead TCP relays are the commonest reason a walk is slow: each one
			// used to burn a whole step. Ask them all at once, then start with
			// one that answered.
			final ordered = await _orderByReachability(
				connection,
				<VpnServer>[target.server, ...alternates],
				resolved,
				request.mode,
			);
			if (ordered.isNotEmpty) {
				final first = resolved[ordered.first.id];
				if (first != null) {
					target = first;
					alternates = ordered.skip(1).toList(growable: true);
				}
			}
		}
		var tried = 1;
		var outcome = await connection.connectAndAwait(
			server: target.server,
			config: target.config,
			countryLabel: target.server.countryCode,
			timeout: walkStepTimeout,
		);

		while (!outcome.connected &&
				outcome.walkable &&
				tried < walkDepth &&
				alternates.isNotEmpty) {
			final nextServer = alternates.removeAt(0);
			final next = resolved[nextServer.id] ??
					await _resolveAlternate(connection, nextServer, request.mode);
			if (next == null) {
				// The source stopped serving this one mid-walk. A skip costs
				// nothing; a failed attempt would cost a step.
				continue;
			}
			tried++;
			connection.reportWalkProgress(
				'The selected server did not answer; trying the next one '
					'($tried of $walkDepth)…',
			);
			target = next;
			outcome = await connection.connectAndAwait(
				server: target.server,
				config: target.config,
				countryLabel: target.server.countryCode,
				timeout: walkStepTimeout,
			);
		}

		if (outcome.connected) {
			return ResolveSuccess(target, notice: success.notice);
		}
		if (tried > 1 && outcome.walkable) {
			// The walk itself is the finding: no ranked server was reachable,
			// which is a different problem from any single server's failure.
			connection.reportWalkExhausted(
				tried: tried,
				message: 'Tried $tried servers in a row and none completed a '
					'handshake. Public relay lists change quickly — try again '
					'shortly.',
			);
		}
		return success;
	}


	/// Looks for a compatible, validated profile after an automatic pick is
	/// rejected. Explicit/favourite/recent picks never call this helper.
	Future<ResolvedTarget?> _resolveProfileFallback({
		required SelectionRequest request,
		required String excludedServerId,
		required PlatformCapabilities? capabilities,
	}) async {
		final requestedCountry = request.countryCode?.toUpperCase();
		final pool = discovery.snapshot.servers.where((candidate) =>
				requestedCountry == null ||
				requestedCountry.isEmpty ||
				candidate.countryCode == requestedCountry).toList(growable: false);
		var attempted = 0;

		for (final scored in selector.rank(_poolForSelection(pool), _scoreContext)) {
			final server = _originalServer(scored.server, pool);
			if (server.id == excludedServerId || !_supports(server.protocol, capabilities)) {
				continue;
			}
			if (attempted >= walkDepth) {
				break;
			}
			attempted++;

			final provider = discovery.providerFor(server);
			if (provider == null) {
				continue;
			}
			final ProviderConfig? fetched;
			try {
				fetched = await provider.fetchConfig(server.id);
			} catch (_) {
				continue;
			}
			if (fetched == null || !_supports(fetched.validated.kind, capabilities)) {
				continue;
			}

			return ResolvedTarget(
				server: server,
				config: fetched.validated,
				selection: Selection(
					server: server,
					mode: request.mode,
					explanation: 'The highest-ranked relay had no usable profile; '
						'using the next compatible relay.',
					fellBack: true,
					fallbackCause: 'profile_unavailable',
				),
				provider: provider,
			);
		}
		return null;
	}

	/// A stale directory can still be used for a real connection attempt. Its
	/// published ping may be old, so allow unknown/offline health *for ranking
	/// only* when no live directory was fetched this process. The original
	/// status is restored before it reaches UI or tunnel state. Withdrawn relays
	/// and locally blacklisted relays remain ineligible.
	List<VpnServer> _poolForSelection(List<VpnServer> servers) {
		if (discovery.hasLiveDirectoryData) {
			return servers;
		}
		return servers.map((server) {
			if (server.status == ServerStatus.offline ||
					server.status == ServerStatus.unknown) {
				return server.copyWith(status: ServerStatus.degraded);
			}
			return server;
		}).toList(growable: false);
	}

	VpnServer _originalServer(VpnServer candidate, List<VpnServer> original) {
		for (final server in original) {
			if (server.id == candidate.id && server.providerId == candidate.providerId) {
				return server;
			}
		}
		return candidate;
	}

	Selection _restoreOriginalSelection(Selection selected, List<VpnServer> original) {
		final server = _originalServer(selected.server, original);
		if (discovery.hasLiveDirectoryData) {
			return Selection(
				server: server,
				mode: selected.mode,
				explanation: selected.explanation,
				fellBack: selected.fellBack,
				fallbackCause: selected.fallbackCause,
			);
		}
		return Selection(
			server: server,
			mode: selected.mode,
			explanation: 'The live server feed is unavailable; trying a previously saved relay. '
					'Its current reachability has not been verified. ${selected.explanation}',
			fellBack: true,
			fallbackCause: 'cached_directory',
		);
	}

	/// Whether [request] may trade a silent server for the next eligible one.
	///
	/// Only the modes that pick by score qualify; the rest express a choice
	/// the ranking merely carries out.
	bool _walks(SelectionRequest request) =>
			request.mode == SelectionMode.recommended ||
				request.mode == SelectionMode.fastest;

	/// The remaining eligible servers for a walk, best first.
	///
	/// Built from the same pool and ranking the selection itself used, so a
	/// walk continues the decision that was already made rather than
	/// starting a second one with different filters.
	List<VpnServer> _alternates(
		SelectionRequest request,
		ResolveSuccess primary,
		PlatformCapabilities? capabilities,
	) {
		final country = request.countryCode;
		final pool = country == null || country.isEmpty
				? discovery.snapshot.servers
				: discovery.snapshot.servers
						.where((server) => server.countryCode == country)
						.toList(growable: false);
		return selector
			.rank(_poolForSelection(pool), _scoreContext)
			.map((scored) => _originalServer(scored.server, pool))
			.where((server) =>
					server.id != primary.target.server.id &&
					_supports(server.protocol, capabilities))
			.take(relayProbe == null ? walkDepth : probeWindow)
			.toList(growable: true);
	}

	/// Fetches and validates the configuration for a walk's next server.
	///
	/// Null when this server cannot be used after all: a source that stops
	/// serving a configuration mid-walk must cost a skip, not the attempt.
	/// The checks mirror [resolve]'s for the same reason the first target
	/// went through them — a server and a configuration must agree before
	/// either one reaches the platform.
	Future<ResolvedTarget?> _resolveAlternate(
		ConnectionController connection,
		VpnServer server,
		SelectionMode mode,
	) async {
		final provider = discovery.providerFor(server);
		if (provider == null) {
			return null;
		}
		final ProviderConfig? fetched;
		try {
			fetched = await provider.fetchConfig(server.id);
		} on AppError {
			return null;
		} catch (_) {
			return null;
		}
		if (fetched == null) {
			return null;
		}
		if (!_supports(fetched.validated.kind, connection.capabilities)) {
			return null;
		}
		return ResolvedTarget(
			server: server,
			config: fetched.validated,
			selection: Selection(
				server: server,
				mode: mode,
				explanation: 'The next eligible server in the ranking.',
			),
			provider: provider,
		);
	}

	/// Whether [config] is a TCP profile that is known to be answering.
	///
	/// `true`: a probe connected. `false`: it did not. `null`: not asked —
	/// UDP has no connection to probe, and a profile with no remote has nothing
	/// to dial — so the relay stays where its ranking put it.
	Future<bool?> _probeRelay(VpnConfiguration config) async {
		final probe = relayProbe;
		final ovpn = config.openVpn;
		if (probe == null || ovpn == null || ovpn.remotes.isEmpty) {
			return null;
		}
		final remote = ovpn.remotes.first;
		final proto = (remote.proto ?? ovpn.proto ?? 'udp').toLowerCase();
		if (!proto.startsWith('tcp')) {
			return null;
		}
		try {
			return await probe(remote.host, remote.port, probeTimeout)
					.timeout(probeTimeout + const Duration(seconds: 1));
		} on Object {
			// A probe that itself breaks proves nothing about the relay.
			return null;
		}
	}

	/// Puts relays that answered (or could not be asked) ahead of relays that
	/// did not, keeping the ranking's order inside each group.
	///
	/// Relays that failed their probe are kept, at the back: if the probe is
	/// what is blocked on this network, dropping them would leave nothing to
	/// try. Servers whose profile cannot be fetched are dropped, as the walk
	/// would have skipped them anyway. Profiles fetched here are stored in
	/// [resolved] so the walk does not fetch them twice.
	Future<List<VpnServer>> _orderByReachability(
		ConnectionController connection,
		List<VpnServer> ranked,
		Map<String, ResolvedTarget> resolved,
		SelectionMode mode,
	) async {
		final window = ranked.take(probeWindow).toList(growable: false);
		final beyond = ranked.skip(probeWindow).toList(growable: false);

		final usable = <VpnServer>[];
		for (final server in window) {
			var target = resolved[server.id];
			target ??= await _resolveAlternate(connection, server, mode);
			if (target == null) {
				continue;
			}
			resolved[server.id] = target;
			usable.add(server);
		}

		final answers = await Future.wait(
			usable.map((server) => _probeRelay(resolved[server.id]!.config)),
		);
		final alive = <VpnServer>[];
		final dead = <VpnServer>[];
		for (var i = 0; i < usable.length; i++) {
			(answers[i] == false ? dead : alive).add(usable[i]);
		}
		return <VpnServer>[...alive, ...dead, ...beyond];
	}
}
