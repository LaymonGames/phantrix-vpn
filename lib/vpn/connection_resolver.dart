import 'package:phantrix_core/phantrix_core.dart';
import 'package:phantrix_platform/phantrix_platform.dart';

import '../discovery/discovery_controller.dart';
import '../l10n/strings.dart';
import 'connection_controller.dart';
import 'relay_probe.dart';
import 'resolve_result.dart';

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
    L10n Function()? language,
  }) : language = language ?? _englishL10n;

  static L10n _englishL10n() => L10n.en;

  /// Where the walk's sentences come from. Same rule as the controller's:
  /// the flow layer writes to the settings the app has, and the selection
  /// sentences answer to the language the user chose.
  final L10n Function() language;

  String _tr(String key, [Map<String, String>? params]) =>
      language().get(key, params);

  /// The country phrase a walk report folds into its sentence.
  ///
  /// Arabic names the country without copying English's "in", so the
  /// phrase is built per language rather than being part of the template.
  String _wherePhrase(String? country) {
    if (country == null || country.isEmpty) {
      return '';
    }
    return language().isRtl ? ' في $country' : ' in $country';
  }

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
  ///
  /// Large enough on purpose: the sweep asks every relay a country lists
  /// (the whole feed's probes run once, in parallel, and TCP dials are
  /// cheap), and the narrower the window the more dead steps the walk
  /// pays for relays it could have ranked out up front.
  static const int probeWindow = 25;

  /// The whole budget the pre-dial probe sweep waits for one relay.
  ///
  /// Shorter than [defaultProbeTimeout] on purpose, because the sweep runs
  /// before the first dial: a relay slow to accept a TCP connection must
  /// not delay the dial by its own slowness. Whatever has not answered by
  /// this budget is treated as never having been asked — it keeps the
  /// ranking's order, and the walk still reaches it.
  static const Duration probeAnswerBudget = Duration(
    milliseconds: 2500,
  );

  /// The default for [probeTimeout].
  static const Duration defaultProbeTimeout = Duration(seconds: 5);

  /// The default for [walkDepth].
  static const int defaultWalkDepth = 12;

  /// The default for [walkStepTimeout].
  ///
  /// A live relay's whole session — TCP, TLS, push, routes — measures three
  /// to five seconds against the volunteer feed, and a challenged one
  /// answers its authentication in about one. Ten seconds is twice the slow
  /// edge of that measurement and still keeps dead relay steps bounded: the
  /// sweep asks reachability up front, so a step that runs its full budget
  /// is a relay the probe could not see, not the common case.
  static const Duration defaultWalkStepTimeout = Duration(seconds: 10);

  /// True when [SelectionMode.nearest] would be a lie, because the user's
  /// position is not known.
  bool get canMeasureDistance => userLatitude != null && userLongitude != null;

  ScoreContext get _scoreContext =>
      ScoreContext(userLatitude: userLatitude, userLongitude: userLongitude);

  /// Every server in the directory, best first, with no eligibility filter.
  ///
  /// Deliberately unfiltered: this is the ranking on its own, so a caller
  /// that wants the servers an attempt could actually use has to apply the
  /// same capability and preference filters the selection path does. Nothing
  /// in the app connects from this list.
  List<ScoredServer> ranked() =>
      selector.rank(discovery.snapshot.servers, _scoreContext);

  /// Whether this build can start a tunnel for [kind] right now.
  ///
  /// The answer comes from the platform, because the engine may be absent:
  /// OpenVPN needs the community engine bundled with the build. A backend
  /// that cannot dial a protocol must not advertise that it can, or the
  /// user picks a location, waits, and is told nothing useful.
  ///
  /// A null [capabilities] means the platform has not said. OpenVPN is then
  /// treated as unavailable — starting a tunnel that cannot be started is
  /// worse than declining it.
  static bool _supports(
    ProtocolKind kind,
    PlatformCapabilities? capabilities,
  ) => switch (kind) {
    // This build runs OpenVPN only. A WireGuard server reaching the
    // directory anyway is refused rather than attempted.
    ProtocolKind.wireGuard => false,
    ProtocolKind.openVpn => capabilities?.openVpn ?? false,
  };

  /// What to tell the user when [kind] is not supported here.
  ///
  /// Written for the person reading it: names the protocol, says plainly
  /// that nothing was attempted, and offers the things that would actually
  /// work. Never "connection failed" — nothing was connected.
  String _protocolRejection(ProtocolKind kind) => _tr('selThisServer', {
    'protocol': kind.label,
    'remedy': _remedyFor({kind}),
  });

  /// What to tell the user when *no* server in the list can be started here.
  ///
  /// "No server passes the health and trust checks" would be a lie in this
  /// case: the servers are healthy, the build simply has no engine for any
  /// of them, and it would send the user away to retry something that
  /// waiting cannot fix. This names the protocols involved and what to do
  /// about them, in the same words a single rejection uses.
  String _noRunnableServer(List<VpnServer> servers, String? country) {
    final kinds = servers.map((server) => server.protocol).toSet();
    final where = country == null || country.isEmpty ? '' : ' in $country';
    final names = kinds.map((kind) => kind.label).join(' or ');
    final it = kinds.length == 1 ? 'it' : 'either of them';
    return _tr('selAllProtocols', {
      'where': where,
      'names': names,
      'it': it,
      'remedy': _remedyFor(kinds),
    });
  }

  /// The remedy for a set of protocols this build cannot start.
  ///
  /// Kept separate from the sentence that reports the problem because the
  /// single-server rejection and the empty-pool message both need it, and a
  /// remedy that drifts between the two would be worse than one that is
  /// slightly repetitive.
  String _remedyFor(Set<ProtocolKind> kinds) {
    final remedies = <String>[
      if (kinds.contains(ProtocolKind.wireGuard))
        _tr('selRemedyWireGuard'),
      if (kinds.contains(ProtocolKind.openVpn))
        _tr('selRemedyOpenVpn'),
    ];
    return '${remedies.join('. ')}.';
  }

  /// Resolves [request] into a usable target.
  ///
  /// [capabilities] is what the running platform can actually start. Left
  /// null, the answer is the conservative one: no engine, so nothing can be
  /// dialled. A server is never fetched, let alone dialled, for a protocol
  /// this build cannot run — it is dropped from the ranking pool entirely,
  /// so a server that would have worked is chosen instead — and if that
  /// leaves nothing at all, the message names the engine that is missing
  /// rather than blaming the network.
  Future<ResolveResult> resolve(
    SelectionRequest request, {
    PlatformCapabilities? capabilities,
  }) async {
    final snapshot = discovery.snapshot;
    final servers = snapshot.servers;
    if (servers.isEmpty) {
      return ResolveFailureResult(
        ResolveFailure.noServers,
        _tr('selNoEndpoints'),
      );
    }

    final country = request.countryCode;
    if (country != null && country.isNotEmpty) {
      final known = servers.any((s) => s.countryCode == country.toUpperCase());
      if (!known) {
        return ResolveFailureResult(
          ResolveFailure.unknownCountry,
          _tr('selUnknownCountry', {'country': country}),
        );
      }
    }

    final selectionPool = _poolForSelection(servers, capabilities);
    final rankedSelection = selector.selectForCountry(
      selectionPool,
      country,
      request,
      _scoreContext,
    );
    var selection = rankedSelection == null
        ? null
        : _restoreOriginalSelection(rankedSelection, servers);
    // A named country is a request to reach that country, and the status
    // column that just judged it was written by the provider's own prober: a
    // relay whose ping could not be measured is listed offline whether or not
    // its OpenVPN process is answering. Both halves of that lie have been
    // seen — relays marked online that never complete a handshake, and relays
    // marked offline that do — so when the requested country has nothing the
    // directory calls usable, its own relays are offered to the walk rather
    // than handing the user a different country they did not ask for. The
    // walk is the only measurement this app trusts; if every relay there
    // really is dead, the attempt says so and names the country it tried.
    //
    // Only a fallback that left the country counts here: `fellBack` is also
    // set for a selection from a stale directory, and that one is already the
    // requested country and must keep its own disclosure.
    final leftTheCountry =
        selection != null &&
        selection.fellBack &&
        selection.server.countryCode != country?.toUpperCase();
    if (country != null &&
        country.isNotEmpty &&
        (selection == null || leftTheCountry)) {
      final own = _countryAsLastResort(
        servers,
        country,
        request,
        capabilities,
      );
      if (own != null) {
        selection = own;
      }
    }
    if (selection == null) {
      // Two different problems end up here. If the pool is empty then the
      // platform filter removed every server — no engine for any of them —
      // and no amount of retrying changes that, so name what is missing
      // instead of blaming health checks. Otherwise servers exist, the
      // country is real, and nothing passed the eligibility rules: a
      // different problem from an empty list, and one that deserves its own
      // message.
      if (selectionPool.isEmpty) {
        return ResolveFailureResult(
          ResolveFailure.noConfiguration,
          _noRunnableServer(servers, country),
        );
      }
      return country == null || country.isEmpty
          ? ResolveFailureResult(
              ResolveFailure.noEligibleServer,
              _tr('selNoEligible'),
            )
          : ResolveFailureResult(
              ResolveFailure.noEligibleServer,
              _tr('selNoEligibleCountry', {'country': country}),
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
        _tr('selSourceGone', {
          'provider': server.providerId,
          'host': server.hostname,
        }),
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
      fetchFailure =
          'Could not download the configuration for ${server.hostname}.';
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
          return ResolveSuccess(
            alternate,
            notice: alternate.selection.explanation,
          );
        }
      }

      if (fetchFailure != null) {
        return ResolveFailureResult(ResolveFailure.fetchFailed, fetchFailure);
      }
      if (fetched == null) {
        return ResolveFailureResult(
          ResolveFailure.noConfiguration,
          _tr('selProfileMissing', {
            'provider': provider.label,
            'host': server.hostname,
          }),
        );
      }
      return ResolveFailureResult(
        ResolveFailure.noConfiguration,
        _tr('selProtocolOnly', {
          'provider': provider.label,
          'host': server.hostname,
          'protocol': fetched.validated.kind.label,
        }),
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
    // Re-read the platform's answer before deciding anything from it. The
    // engine list is a fact about the machine, and the machine may have
    // changed since startup.
    await connection.refreshCapabilities();
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
    // Ids the TCP probe asked and heard nothing back from. They are still
    // walked — the probe itself may be what this network blocks — but the
    // count of them is the one fact that separates "the list moved on" from
    // "nothing here can be reached", so it is carried into the failure.
    var silent = const <String>{};
    Future<({List<VpnServer> ordered, Set<String> silent})>? sweepSettled;
    if (relayProbe != null && alternates.isNotEmpty) {
      // Dead TCP relays are the commonest reason a walk is slow: each one
      // used to burn a whole step. The sweep asks the pool together, but
      // the dial does not wait for the whole sweep: the moment the
      // ranking's best candidate answers a TCP connection, the engine
      // starts. The rest of the ordering matters only after a failed step,
      // so it is consumed once the dial is in flight — by then every probe
      // that decides it has long answered.
      final sweep = _beginReachabilitySweep(
        connection,
        <VpnServer>[target.server, ...alternates],
        resolved,
        request.mode,
      );
      sweepSettled = sweep.settled;
      final picked = await sweep.dialPick;
      if (picked != null) {
        target = picked;
      }
    }
    var tried = 1;
    final dialled = <String>{target.server.id};
    var outcome = await connection.connectAndAwait(
      server: target.server,
      config: target.config,
      countryLabel: target.server.countryCode,
      timeout: walkStepTimeout,
    );
    if (sweepSettled != null && !outcome.connected) {
      // The dial is over — connected walks never need the ordering. A
      // settled sweep that survives past this point is discarded: its
      // probes answer at their own budget and nothing reads them.
      final orderedAndSilent = await sweepSettled;
      silent = orderedAndSilent.silent;
      alternates = orderedAndSilent.ordered
          .where((candidate) => candidate.id != target.server.id)
          .toList(growable: true);
    }

    // The one relay whose engine reached a full handshake but whose exit
    // address could not be confirmed (`leak.*`). That is the strongest
    // failure a walk can own: everything else it met were relays that never
    // negotiated at all. An engine that reached `Initialization Sequence
    // Completed` is a relay that answers — and SoftEther relays routinely
    // refuse or fumble a first attempt and accept a later one. Measured
    // live: the engine archive shows a relay completing TLS, push and
    // routes, the exit-address read failing underneath it, the walk moving
    // on, and the final report saying no relay had been reached — while a
    // working tunnel stood there being torn down. So: the most recent relay
    // to reach that state is remembered, and if the walk ends without a
    // success, it is given exactly one more attempt before the failure is
    // reported.
    var unconfirmedHandshake =
        outcome.code != null && outcome.code!.startsWith('leak.')
        ? target
        : null;
    while (!outcome.connected &&
        outcome.walkable &&
        tried < walkDepth &&
        alternates.isNotEmpty) {
      final nextServer = alternates.removeAt(0);
      final next =
          resolved[nextServer.id] ??
          await _resolveAlternate(connection, nextServer, request.mode);
      if (next == null) {
        // The source stopped serving this one mid-walk. A skip costs
        // nothing; a failed attempt would cost a step.
        continue;
      }
      tried++;
      dialled.add(next.server.id);
      connection.reportWalkProgress(
        _tr('walkNextServer', {'tried': '$tried', 'depth': '$walkDepth'}),
      );
      target = next;
      outcome = await connection.connectAndAwait(
        server: target.server,
        config: target.config,
        countryLabel: target.server.countryCode,
        timeout: walkStepTimeout,
      );
      if (!outcome.connected &&
          outcome.code != null &&
          outcome.code!.startsWith('leak.')) {
        unconfirmedHandshake = target;
      }
    }

    // The second attempt for the relay that negotiated but did not verify.
    // One more is the whole allowance: a relay that fumbles twice in a row
    // is not the one a retry is for, and the walk's report must remain an
    // honest summary rather than grow into a permanent loop.
    var retriedUnconfirmedHandshake = false;
    if (!outcome.connected && unconfirmedHandshake != null) {
      retriedUnconfirmedHandshake = true;
      target = unconfirmedHandshake;
      connection.reportWalkProgress(_tr('walkSecondTry'));
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
        message: _walkExhaustedMessage(
          tried: tried,
          country: request.countryCode,
          neverAnswered: dialled.where(silent.contains).length,
          retriedUnconfirmedHandshake: retriedUnconfirmedHandshake,
        ),
      );
    }
    return success;
  }

  /// Why a walk ran out of servers, in the terms the user can act on.
  ///
  /// "Try again shortly" is only honest when the relays were heard from: one
  /// that answers TCP and then fails may simply be a relay the list has moved
  /// past. One that never answers at all is not — no retry reaches it — and
  /// when any of the walk stayed silent, that is the finding worth naming,
  /// because the answer is a different country, not another attempt at this
  /// one.
  String _walkExhaustedMessage({
    required int tried,
    required String? country,
    required int neverAnswered,
    required bool retriedUnconfirmedHandshake,
  }) {
    final where = _wherePhrase(country);
    if (retriedUnconfirmedHandshake) {
      return _tr('walkExhaustedRetried', {'tried': '$tried', 'where': where});
    }
    if (neverAnswered == 0) {
      return _tr('walkExhaustedSilent', {'tried': '$tried', 'where': where});
    }
    return _tr('walkExhaustedDark', {
      'tried': '$tried',
      'where': where,
      'silent': '$neverAnswered',
    });
  }

  /// Looks for a compatible, validated profile after an automatic pick is
  /// rejected. Explicit/favourite/recent picks never call this helper.
  Future<ResolvedTarget?> _resolveProfileFallback({
    required SelectionRequest request,
    required String excludedServerId,
    required PlatformCapabilities? capabilities,
  }) async {
    final requestedCountry = request.countryCode?.toUpperCase();
    final pool = discovery.snapshot.servers
        .where(
          (candidate) =>
              requestedCountry == null ||
              requestedCountry.isEmpty ||
              candidate.countryCode == requestedCountry,
        )
        .toList(growable: false);
    var attempted = 0;

    // A named country follows the same list the selection just used — its own
    // relays, verification status relaxed — so an unverified relay with a
    // broken profile is skipped in favour of the next one in the country
    // rather than ending the attempt. Everything else ranks normally.
    final candidates = requestedCountry == null || requestedCountry.isEmpty
        ? selector
              .rank(_poolForSelection(pool, capabilities), _scoreContext)
              .map((scored) => _originalServer(scored.server, pool))
              .toList(growable: false)
        : _rankCountryIncludingUnverified(pool, requestedCountry, capabilities);

    for (final server in candidates) {
      if (server.id == excludedServerId ||
          !_supports(server.protocol, capabilities)) {
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
          explanation: _tr('selProfileFallbackNote'),
          fellBack: true,
          fallbackCause: 'profile_unavailable',
        ),
        provider: provider,
      );
    }
    return null;
  }

  /// The servers ranking may consider: only the ones this build can dial.
  ///
  /// A server whose protocol this build cannot start is removed *before* the
  /// ranking rather than after the pick. Ranking predicts which server will
  /// answer, not which one can be dialled at all, so leaving an unrunnable
  /// server in the pool lets it win and turns the whole attempt into a
  /// refusal — with a server that would have worked sitting one rank below
  /// it. It is also the slow path: the refusal only arrives after selection,
  /// configuration fetch and validation have all run.
  ///
  /// A stale directory can still be used for a real connection attempt. Its
  /// published ping may be old, so offline and unknown relays are downgraded
  /// to degraded here — rankable, and still marked unverified. The original
  /// status is restored before it reaches UI or tunnel state.
  ///
  /// This filters on what the machine can run, and nothing else. There is no
  /// local blocklist: a relay that failed once is still eligible on the next
  /// attempt, ranked later rather than banned.
  List<VpnServer> _poolForSelection(
    List<VpnServer> servers,
    PlatformCapabilities? capabilities,
  ) {
    final eligible = servers
        .where((server) => _supports(server.protocol, capabilities))
        .toList(growable: false);
    if (discovery.hasLiveDirectoryData) {
      return eligible;
    }
    return eligible
        .map((server) {
          if (server.status == ServerStatus.offline ||
              server.status == ServerStatus.unknown) {
            return server.copyWith(status: ServerStatus.degraded);
          }
          return server;
        })
        .toList(growable: false);
  }

  VpnServer _originalServer(VpnServer candidate, List<VpnServer> original) {
    for (final server in original) {
      if (server.id == candidate.id &&
          server.providerId == candidate.providerId) {
        return server;
      }
    }
    return candidate;
  }

  Selection _restoreOriginalSelection(
    Selection selected,
    List<VpnServer> original,
  ) {
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
      explanation: _tr('selCachedDirectoryNote', {'note': selected.explanation}),
      fellBack: true,
      fallbackCause: 'cached_directory',
    );
  }

  /// The requested country's own relays, for when the directory has given up
  /// on all of them.
  ///
  /// See the call site: this is the difference between "Greece is offline"
  /// and "Greece answered on the first dial", and it is deliberately
  /// country-scoped. Only the country the user named is pinned to a relay the
  /// directory doubts; an automatic request never named a country, so it
  /// keeps substituting freely, which is the behaviour its caller asked for.
  Selection? _countryAsLastResort(
    List<VpnServer> servers,
    String country,
    SelectionRequest request,
    PlatformCapabilities? capabilities,
  ) {
    final ranked = _rankCountryIncludingUnverified(
      servers,
      country,
      capabilities,
    );
    if (ranked.isEmpty) {
      return null;
    }
    return Selection(
      server: ranked.first,
      mode: request.mode,
      explanation: _tr('selCountryOfflineNote', {
        'country': country.toUpperCase(),
      }),
      fellBack: false,
    );
  }

  /// The country's relays this build could dial, ranked even where the
  /// directory marks them unusable.
  ///
  /// Offline and unknown are the two statuses a provider produces by failing
  /// to *measure* a relay rather than by observing it go away — which is why
  /// the stale-directory path downgrades exactly those two as well. A
  /// withdrawn relay is deliberately still excluded: that is the source
  /// saying the endpoint is gone, and no ping of ours can overrule it.
  List<VpnServer> _rankCountryIncludingUnverified(
    List<VpnServer> servers,
    String country,
    PlatformCapabilities? capabilities,
  ) {
    final upper = country.toUpperCase();
    final inCountry = servers
        .where((server) => server.countryCode == upper)
        .where((server) => _supports(server.protocol, capabilities))
        .toList(growable: false);
    if (inCountry.isEmpty) {
      return const <VpnServer>[];
    }
    final relaxed = inCountry
        .map(
          (server) =>
              server.status == ServerStatus.offline ||
                  server.status == ServerStatus.unknown
              ? server.copyWith(status: ServerStatus.degraded)
              : server,
        )
        .toList(growable: false);
    return selector
        .rank(relaxed, _scoreContext)
        .map((scored) => _originalServer(scored.server, servers))
        .toList(growable: false);
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
    final ranked = selector
        .rank(_poolForSelection(pool, capabilities), _scoreContext)
        .map((scored) => _originalServer(scored.server, pool))
        .toList(growable: true);
    if (country != null && country.isNotEmpty) {
      // A country walk that runs out of rankable relays continues into the
      // same country's unverified ones, for the reason the selection relaxed
      // them in the first place. They go after every rankable candidate, so a
      // relay the directory vouches for is never queued behind one it doubts.
      final seen = ranked.map((server) => server.id).toSet();
      for (final server in _rankCountryIncludingUnverified(
        pool,
        country,
        capabilities,
      )) {
        if (seen.add(server.id)) {
          ranked.add(server);
        }
      }
    }
    return ranked
        .where(
          (server) =>
              server.id != primary.target.server.id &&
              _supports(server.protocol, capabilities),
        )
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
        explanation: _tr('selNextInRankNote'),
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
      return await probe(
        remote.host,
        remote.port,
        probeTimeout,
      ).timeout(probeTimeout + const Duration(seconds: 1));
    } on Object {
      // A probe that itself breaks proves nothing about the relay.
      return null;
    }
  }

  /// Runs the reachability sweep and returns its two consumers separately.
  ///
  /// The [dialPick] future is the ranking's best candidate that answered a
  /// TCP connection inside [probeAnswerBudget], or null when nothing proved
  /// alive — the dial then goes to the ranking's own first choice. The
  /// probes all start together, so the pick costs the sweep a single round
  /// trip for a healthy best candidate, not the whole budget; the scan
  /// reads the answers in rank order and silent relays only rank-behind.
  ///
  /// The [settled] future is the full ordering — alive candidates first in
  /// rank order, then the silent ones, then whatever was beyond the probe
  /// window — plus the set of ids that answered their probe with a failed
  /// connection. It is needed only when the walk has to move past a relay,
  /// so it is awaited after the dial is in flight, not before it starts.
  ///
  /// Relays that failed their probe are kept, at the back: if the probe is
  /// what is blocked on this network, dropping them would leave nothing to
  /// try. Servers whose profile cannot be fetched are dropped, as the walk
  /// would have skipped them anyway. Profiles fetched here are stored in
  /// [resolved] so the walk does not fetch them twice.
  ///
  /// Configuration fetches run together rather than in a serial loop: for a
  /// freshly refreshed list each one is a network read, and a window of
  /// them one after another cost seconds before the first dial even
  /// started — the dial latency this sweep exists to shorten, not add to.
  ({Future<ResolvedTarget?> dialPick, Future<({List<VpnServer> ordered, Set<String> silent})> settled})
  _beginReachabilitySweep(
    ConnectionController connection,
    List<VpnServer> ranked,
    Map<String, ResolvedTarget> resolved,
    SelectionMode mode,
  ) {
    final window = ranked.take(probeWindow).toList(growable: false);
    final beyond = ranked.skip(probeWindow).toList(growable: false);

    final configs = Future.wait(
      window.map((entry) async {
        final target =
            resolved[entry.id] ??
            await _resolveAlternate(connection, entry, mode);
        return (server: entry, target: target);
      }),
    );

    var answers = const <(ResolvedTarget, Future<bool?>)>[];
    Future<void> prepareProbes = configs.then((targets) {
      final probed = <(ResolvedTarget, Future<bool?>)>[];
      for (final entry in targets) {
        final target = entry.target;
        if (target == null) {
          continue;
        }
        resolved[target.server.id] = target;
        try {
          // One budget per probe, tighter than the probe's own timeout on
          // purpose: a relay slow to accept a TCP connection must not hold
          // the dial hostage by seconds, whatever its answer would have
          // been. Outlasting the budget answers null, the same as an
          // unasked relay: it stays in the ranking's order and the walk
          // still reaches it.
          probed.add((target, _probeRelay(target.config).timeout(
            probeAnswerBudget,
            onTimeout: () => null,
          )));
        } on Object {
          // The ask itself failing proves nothing about the relay.
          probed.add((target, Future<bool?>.value(null)));
        }
      }
      answers = probed;
    });

    Future<ResolvedTarget?> dialPick() async {
      await prepareProbes;
      // Read the answers in rank order: the ranking is the only opinion
      // about which relay the user would want to be on. A future that
      // already completed answers instantly, so a silent best candidate
      // does not stack its budget on the relay ranked after it.
      for (final (target, answer) in answers) {
        if (await answer == true) {
          return target;
        }
      }
      return null;
    }

    Future<({List<VpnServer> ordered, Set<String> silent})> full() async {
      await prepareProbes;
      final alive = <VpnServer>[];
      final dead = <VpnServer>[];
      final silent = <String>{};
      for (final (target, answer) in answers) {
        if (await answer == false) {
          silent.add(target.server.id);
          dead.add(target.server);
        } else {
          alive.add(target.server);
        }
      }
      return (ordered: <VpnServer>[...alive, ...dead, ...beyond], silent: silent);
    }

    return (dialPick: dialPick(), settled: full());
  }
}
