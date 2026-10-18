import 'dart:async';
import 'dart:developer' as developer;

import 'package:phantrix_core/phantrix_core.dart';
import 'package:phantrix_platform/phantrix_platform.dart';

import '../l10n/strings.dart';
import '../settings/settings_controller.dart';
import 'connect_attempt_outcome.dart';
import 'connection_view.dart';
import 'leak_check.dart';
import 'openvpn_profile.dart';

/// Drives the connection.
///
/// The only object allowed to move the state machine. It follows one rule
/// strictly: `connected` is only ever set after the tunnel has been
/// established *and* verified. A platform reporting `established` maps to the
/// connecting state until verification returns.
///
/// Every attempt is bounded: [connectTimeout] arms a deadline when consent
/// is granted, and the deadline — not the engine — decides when a silent
/// attempt has become a failure. Nothing in this class can sit in
/// `preparing`, `connecting` or `reconnecting` forever.
class ConnectionController {
  ConnectionController({
    required this.platform,
    required this.settings,
    LeakCheck? leakCheck,
    this.connectTimeout = defaultConnectTimeout,
    L10n Function()? language,
  }) : language = language ?? _englishL10n {
    _leakCheck = leakCheck ?? LeakCheck();
    // The attempt is announced in the user's language from the first frame.
    _statusMessage = _tr('flowNotConnected');
    _platformEvents = platform.events.listen(_onPlatformEvent);
    unawaited(_loadCapabilities());
  }

  static L10n _englishL10n() => L10n.en;

  /// Re-reads the user's chosen language on every message, so a switch in
  /// the settings screen takes effect on the next sentence without any
  /// plumbing: the messages live in the flow layer, they answer to the
  /// settings it already holds.
  L10n get _l10n => language();

  /// The user's sentence for [key], with its placeholders filled.
  String _tr(String key, [Map<String, String>? params]) =>
      _l10n.get(key, params);

  /// How long an attempt may run before it is reported as failed.
  ///
  /// Long enough for a slow volunteer relay to answer a handshake, short
  /// enough that "Connecting…" never becomes a decorative label. Injected
  /// so tests can watch the deadline fire without waiting for it.
  static const Duration defaultConnectTimeout = Duration(seconds: 45);

  /// The platform bridge.
  final PhantrixPlatform platform;

  /// The user's settings, read live so a change takes effect immediately.
  final SettingsController settings;

  /// The deadline for a single connection attempt.
  final Duration connectTimeout;

  /// Where the flow's sentences come from. Injectable so a test reads
  /// English regardless of the settings it carries.
  final L10n Function() language;

  /// Re-runs discovery and selection for the user's saved preference.
  ///
  /// Wired by the app scope — the resolver and discovery controller live
  /// there, not here. Used by [retry] when the failure was "there was
  /// nothing to connect to": only a fresh selection can fix that, and
  /// pretending to restart a tunnel that was never started is exactly the
  /// stuck-`preparing` state this exists to prevent.
  Future<void> Function()? retrySelection;

  /// The outcome of the attempt currently in flight, if a caller is
  /// awaiting one through [connectAndAwait].
  Completer<ConnectAttemptOutcome>? _attemptOutcome;

  /// The attempt generation, bumped whenever an attempt starts or is
  /// abandoned.
  ///
  /// A cancelled [connect] does not stop in mid-air: it is suspended at
  /// whatever platform call it had in flight, and it wakes up again later.
  /// Every continuation re-checks the generation it was started with and
  /// returns without touching the state machine when it no longer matches,
  /// because a continuation belonging to an abandoned attempt would
  /// otherwise write its failure over the attempt that replaced it — and
  /// an attempt the user cancelled must not come back as an error card.
  int _attemptEpoch = 0;

  /// The generation whose tunnel the platform was last asked to launch.
  ///
  /// Read by a stale continuation to decide whether it may still stop the
  /// tunnel its own call brought up. When a newer attempt has already
  /// claimed the platform, that tunnel belongs to *it*, and stopping here
  /// would tear down the connection the user has since asked for.
  int _launchedEpoch = 0;

  /// The teardown a previous failure started, if any.
  ///
  /// A new attempt waits for it: starting a tunnel while the previous one
  /// is still stopping is how a platform ends up racing its own engine,
  /// and a walk across servers would do it on every step.
  Future<void> _lastStop = Future<void>.value();

  /// The teardown currently running, if any.
  ///
  /// See [disconnect]: a second caller joins this instead of starting a
  /// teardown that would fight it over [_teardownRequested].
  Future<void>? _teardownInFlight;

  /// The budget the armed deadline is running against, so the deadline's
  /// own message reports the number that actually applied.
  Duration? _deadlineBudget;

  /// The handshake budget of the attempt in flight.
  ///
  /// Kept apart from [_deadlineBudget] because the deadline is re-armed at
  /// each phase (launch, handshake, verification), and each phase must start
  /// from the attempt's own budget rather than from whatever the previous
  /// phase left running.
  Duration _attemptBudget = defaultConnectTimeout;

  /// How long verification of an established tunnel may take.
  ///
  /// Verification reads the exit address through the tunnel, which on a slow
  /// volunteer relay can take longer than the handshake itself. It gets its
  /// own budget so a relay that *did* connect is not abandoned because the
  /// handshake used up the time the address check needed.
  static const Duration verifyBudget = Duration(seconds: 30);

  /// The longest the native side may take to launch the tunnel.
  ///
  /// On Windows that covers the administrator prompt, which lasts as long as
  /// the person takes to answer it. The handshake clock must not run while
  /// that prompt is open.
  static const Duration launchGrace = Duration(seconds: 100);

  /// The longest [connect] will wait for a teardown to settle before
  /// reporting that it could not start.
  ///
  /// Generous against a real teardown, which is milliseconds of routing
  /// cleanup, and short enough that a platform which has stopped answering
  /// costs the user one bounded wait rather than an attempt that never
  /// begins.
  static const Duration settleTimeout = Duration(seconds: 5);

  /// True while [platform.startTunnel] has not returned yet.
  bool _launching = false;
  final Stopwatch _launchWatch = Stopwatch();

  StreamSubscription<PlatformEvent>? _platformEvents;
  final _views = StreamController<ConnectionView>.broadcast();

  /// Feeds a platform event as though the native side had sent it.
  ///
  /// Exposed for tests. Production code never calls this: the only real
  /// source of events is [platform]. Keeping it on the class rather than
  /// reaching into the private handler means the test exercises the same
  /// state-machine path the platform does, instead of a parallel one that
  /// could drift.
  void debugReceive(PlatformEvent event) {
    unawaited(_onPlatformEvent(event));
  }

  /// Sets the pre-connection address the verifier compares against.
  ///
  /// Exposed for tests so a case can fix the baseline instead of depending
  /// on a probe that would need the network.
  void debugSetBaselineForTest(String? baseline) {
    _ipBeforeTunnel = baseline;
  }

  PlatformCapabilities _capabilities = PlatformCapabilities.web;
  PlatformCapabilities get capabilities => _capabilities;

  /// Whether the OS itself is currently blocking traffic outside a VPN.
  ///
  /// A pass-through to the platform, read live on every call. The settings
  /// screen awaits it when it builds, so the row always shows the current
  /// system state rather than whatever was true when the app launched.
  Future<bool> systemLockdownActive() => platform.systemLockdownActive();

  /// Opens the operating system's own VPN settings screen.
  Future<void> openSystemVpnSettings() => platform.openSystemVpnSettings();

  /// Records (or removes) the app's start-at-sign-in entry.
  ///
  /// A pass-through to the platform; false means the machine refused, and
  /// the settings screen puts the switch back rather than keeping a promise
  /// the machine would not make.
  Future<bool> setStartOnBoot(bool enabled) => platform.setStartOnBoot(enabled);

  VpnState _current = VpnState.disconnected;
  ConnectionSession _session = ConnectionSession.none;
  String _statusMessage = 'Not connected.';
  String? _errorMessage;
  String? _errorCode;
  bool _canRetry = false;
  String? _lastFallback;
  String? _ipBeforeTunnel;
  bool _disposed = false;

  /// The server the current or most recent attempt used.
  String? _selectedLabel;

  /// The exact attempt last started, kept so [retry] can replay it rather
  /// than restart a state machine with nothing behind it.
  VpnServer? _lastServer;
  VpnConfiguration? _lastConfig;
  String? _lastCountryLabel;

  /// Protocol of the attempt in flight; null when no attempt has run.
  ///
  /// This build runs OpenVPN only, so the value is a constant in practice —
  /// it is kept as the recorded fact of what was dialled, which is what the
  /// handshake wording and the verification pass are read against.
  ProtocolKind? _activeKind;

  /// Whether the current failure came from a tunnel attempt that can be
  /// replayed as-is. Selection and configuration failures set this false:
  /// replaying them would restart something that never reached the engine.
  bool _failureReplayable = false;

  /// The deadline that keeps an attempt from waiting forever.
  Timer? _connectDeadline;

  /// True while [disconnect] is tearing the tunnel down at the user's
  /// request.
  ///
  /// Distinguishes "the engine confirmed a teardown we asked for" from
  /// "the engine died mid-attempt": an `idle` event arriving while this is
  /// set is the confirmation, and is reported silently; the same event
  /// with an attempt in flight and this unset is an unexpected death and
  /// becomes a failure with a retry.
  bool _teardownRequested = false;

  /// The verifier. Injectable so tests can supply a fetcher that never opens
  /// a socket.
  late final LeakCheck _leakCheck;

  /// The device's current public exit address, measured the same way the
  /// connect flow verifies it. Diagnostics uses this so the screen's numbers
  /// come from a real request, not a canned value.
  Future<String?> readPublicIp() =>
      _leakCheck.currentIp(timeout: const Duration(seconds: 8));

  /// The engine's last reported handshake, or null when none has happened.
  DateTime? _lastHandshakeAt;

  /// Real byte counters read from the engine, for display. Surfaced through
  /// [ConnectionView] rather than kept private, so a stale tunnel's counters
  /// are visible instead of frozen at zero.
  PlatformTraffic _traffic = PlatformTraffic.empty;

  /// Guards against two overlapping verification passes, which the engine's
  /// per-second statistics could otherwise trigger.
  bool _verificationInFlight = false;

  /// The last view, so a screen's `initState` can read a value immediately.
  ConnectionView get currentView => ConnectionView(
    state: _current,
    session: _session,
    statusMessage: _statusMessage,
    errorMessage: _errorMessage,
    errorCode: _errorCode,
    canRetry: _canRetry,
    platform: _capabilities,
    lastFallback: _lastFallback,
    traffic: _traffic,
    lastHandshakeAt: _lastHandshakeAt,
    selectedLabel: _selectedLabel,
    ipv6Policy: settings.data.ipv6,
  );

  Stream<ConnectionView> get views => _views.stream;

  Future<void> _loadCapabilities() async {
    _capabilities = await platform.capabilities();
    _emit();
  }

  /// Re-reads what the platform can start, for the paths that are about to
  /// decide something from it.
  ///
  /// The probe at construction is not enough on a platform where the engine
  /// is something that can appear or disappear while the app is open. A
  /// platform that cannot answer keeps its previous answer — a failed probe
  /// is not evidence that an engine went away.
  Future<void> refreshCapabilities() async {
    final PlatformCapabilities fresh;
    try {
      fresh = await platform.capabilities();
    } on Object {
      return;
    }
    final changed = fresh.openVpn != _capabilities.openVpn;
    _capabilities = fresh;
    if (changed) {
      _emit();
    }
  }

  void _emit() {
    if (!_disposed) {
      _views.add(currentView);
    }
  }

  Future<void> _onPlatformEvent(PlatformEvent event) async {
    if (event.capabilities != null) {
      _capabilities = event.capabilities!;
    }
    if (event.errorCode != null) {
      // Same rule as a `failed` tunnel state below: an error is a
      // statement about an attempt. With none running — because the user
      // cancelled one, or this is the platform answering its own stop —
      // reporting it would hand the user an error card for the very
      // teardown they asked for.
      if (_current.isTransitioning || _current.isConnected) {
        _fail(event.errorCode!, event.message ?? _tr('flowTunnelFailed'));
      }
      return;
    }
    switch (event.state) {
      case PlatformTunnelState.connecting:
        if (_current == VpnState.preparing) {
          _apply(VpnEvent.tunnelStarting(), _tr('flowNegotiating'));
        }
      case PlatformTunnelState.established:
        // The interface is up. That is not yet a working tunnel: the
        // peer has not necessarily answered a single handshake yet, so
        // this only advances the state machine and waits. As with the
        // handshake branch below, an undated event must not erase a
        // timestamp an earlier event already established.
        _absorbTraffic(event.traffic);
        _lastHandshakeAt =
            _handshakeFrom(event.lastHandshakeAtMillis) ?? _lastHandshakeAt;
        _apply(VpnEvent.tunnelStarting(), _interfaceUpMessage());
      case PlatformTunnelState.handshaked:
        // A handshake has actually completed. This is the first point at
        // which verification is meaningful, because it is the first
        // point at which the peer is known to be real.
        //
        // An undated duplicate must never clobber a dated handshake:
        // the engine reports the handshake state and its timestamp as
        // two events, and the undated one arriving second would
        // otherwise erase the evidence the first one carried — tearing
        // down a live tunnel on a reconnect, or failing a fresh one.
        _lastHandshakeAt =
            _handshakeFrom(event.lastHandshakeAtMillis) ?? _lastHandshakeAt;
        _absorbTraffic(event.traffic);
        await _verifyAndPromote();
      case PlatformTunnelState.reconnecting:
        if (_current.isConnected) {
          _apply(VpnEvent.networkChanged(), _tr('flowNetworkChanged'));
          // Recovery is an attempt like any other: bounded, or the
          // app would claim "Reconnecting…" long after the network
          // is never coming back.
          if (_current == VpnState.reconnecting) {
            _armConnectDeadline();
          }
        } else {
          _absorbTraffic(event.traffic);
        }
      case PlatformTunnelState.idle:
        // Consent owns the flow while it is pending: the platform
        // emits idle at start-up and after teardown, and neither is
        // information about a tunnel that was never started.
        if (_current == VpnState.permissionRequired) {
          break;
        }
        if (_launching) {
          // A launch is in flight for the attempt now running, so
          // this idle can only be a straggler from the teardown that
          // preceded it. Reading it as the new attempt's death is
          // exactly how cancelling one attempt and starting the next
          // would fail the next one before it began.
          break;
        }
        if (_current == VpnState.preparing ||
            _current == VpnState.connecting ||
            _current == VpnState.reconnecting) {
          // An attempt is in flight that nobody cancelled: the engine
          // died rather than being stopped. Reporting "Not connected"
          // with no reason would leave the user staring at a button
          // that just did nothing, so this is a failure with a retry,
          // not a silent return to idle.
          if (!_teardownRequested) {
            _fail('tunnel.died', _tr('flowTunnelDied'));
            unawaited(_stopAfterFailure());
            break;
          }
        }
        if (_current.isConnected || _current.isTransitioning) {
          _apply(VpnEvent.disconnected());
          _statusMessage = _tr('flowNotConnected');
          _session = ConnectionSession.none;
          _traffic = PlatformTraffic.empty;
          _lastHandshakeAt = null;
        }
      case PlatformTunnelState.disconnecting:
        // The engine is going down. Enter the explicit teardown step
        // so the UI never says "Connected" while it does.
        if (_current == VpnState.permissionRequired) {
          break;
        }
        if (_current.isConnected ||
            (_current.isTransitioning && _current != VpnState.disconnecting)) {
          _apply(VpnEvent.disconnectRequested(), _tr('flowDisconnecting'));
        }
      case PlatformTunnelState.failed:
        // A failure is a statement about an attempt. Between attempts,
        // or after the user has cancelled one, the platform reporting
        // a problem describes a tunnel that is already gone — turning
        // it into an error card would blame the user for the stop they
        // asked for.
        if (_current.isTransitioning || _current.isConnected) {
          _fail('tunnel.failed', event.message ?? _tr('flowTunnelFailed'));
        }
      case PlatformTunnelState.preparing:
        // A normal start-up state, not a problem. The service has been
        // asked to come up and is building the engine's configuration.
        // This used to be grouped with `revoked`, which meant the very
        // first event of every connection attempt was interpreted as
        // "permission withdrawn" and the app blocked itself.
        _apply(VpnEvent.prepareRequested(), _tr('flowPreparing'));
      case PlatformTunnelState.revoked:
        _apply(
          const VpnEvent.permissionMissing(
            'VPN permission was withdrawn by the system.',
          ),
        );
    }
  }

  /// Folds a sample of the engine's counters into the view and session.
  ///
  /// The session panel renders [ConnectionSession.rxBytes] and friends, so
  /// without this the stats would sit at `0 B` forever while real bytes
  /// crossed the tunnel — a fabricated-looking number in the one place the
  /// app promises measurements.
  void _absorbTraffic(PlatformTraffic traffic) {
    _traffic = traffic;
    _session = _session.copyWith(
      rxBytes: traffic.rxBytes,
      txBytes: traffic.txBytes,
      rxRate: traffic.rxRate,
      txRate: traffic.txRate,
      lastHandshakeAt: traffic.lastHandshake,
      protocolLabel: traffic.protocolLabel,
    );
  }

  /// The state's own short label, in the user's language, for the places
  /// where only a state fits: a walk summary and a selection failure leave
  /// the state's name as the status, and the state machine's own labels are
  /// English-only.
  String _stateStatusLabel() => _l10n.get('state.${_current.name}');

  /// What to call the moment the interface exists, in the protocol's own
  /// vocabulary.
  String _interfaceUpMessage() => _tr('flowInterfaceUp');

  /// Turns the engine's epoch millis into a local time.
  ///
  /// Null when absent, which the verifier treats as "no handshake has
  /// happened" rather than as "a handshake at the epoch". Conflating those
  /// two is exactly how a broken tunnel gets reported as healthy.
  DateTime? _handshakeFrom(int? epochMillis) =>
      epochMillis == null || epochMillis <= 0
      ? null
      : DateTime.fromMillisecondsSinceEpoch(epochMillis);

  /// Runs verification and promotes the connection only if it passes.
  ///
  /// This is the single place the app may report `connected`. It requires, in
  /// order: a completed handshake, a handshake recent enough to trust, and a
  /// public address that differs from the pre-connection one. Anything less
  /// is reported as a failure with the specific reason, and the tunnel is torn
  /// down rather than left half-connected.
  ///
  /// The protocol decides what the evidence is *called*, not what counts:
  /// OpenVPN's TLS handshake behind "Initialization Sequence Completed" must
  /// be engine-reported and dated, and is judged by the same freshness and
  /// address rules as any other.
  Future<void> _verifyAndPromote() async {
    if (_current != VpnState.connecting &&
        _current != VpnState.reconnecting &&
        _current != VpnState.preparing) {
      // Already connected and re-verified; the engine's periodic
      // statistics should not restart verification.
      return;
    }
    if (_verificationInFlight) {
      return;
    }
    final epoch = _attemptEpoch;
    _verificationInFlight = true;
    // The handshake is done; what remains is reading the exit address
    // through the tunnel. That gets its own budget instead of whatever the
    // handshake left of the attempt's, so a relay that connected is not
    // abandoned (and an automatic walk moved on) over a slow address check.
    _armConnectDeadline(verifyBudget);
    try {
      _apply(VpnEvent.tunnelUp(), _tr('flowHandshaked'));
      final verifyWatch = Stopwatch()..start();
      final outcome = await _leakCheck.verify(
        baseline: _ipBeforeTunnel,
        handshakeAt: _lastHandshakeAt,
        protocol: _activeKind ?? ProtocolKind.openVpn,
        l10n: _l10n,
      );
      developer.log(
        'phase=post_handshake_verification duration_ms=${verifyWatch.elapsedMilliseconds} '
        'verified=${outcome.verified} external_ip_observed=${outcome.publicIp != null}',
        name: 'phantrix.connection',
      );

      // Re-check *after* the await. Verification performs real network I/O
      // and can take seconds; the user may have pressed Disconnect, the
      // tunnel may have dropped, or the engine may have reported a failure
      // while it was in flight. Applying the result of a verification that
      // belongs to a connection which no longer exists is how a UI ends up
      // showing session details for a tunnel that is gone. The state
      // machine would reject the transition, but the session fields would
      // still have been overwritten.
      //
      // The generation is checked beside the state, because the state
      // alone is not enough: cancel and reconnect quickly enough and
      // this awaiting call finds `connecting` again — the *new*
      // attempt's — and would judge the replacement on a measurement
      // taken for the one that was abandoned.
      //
      // Removing this block makes
      // `a late verification result cannot revive a dead connection` in
      // test/connection_state_test.dart fail, so the guard is covered.
      if (epoch != _attemptEpoch ||
          (_current != VpnState.connecting &&
              _current != VpnState.reconnecting &&
              _current != VpnState.preparing)) {
        return;
      }

      if (outcome.verified) {
        _session = _session.copyWith(
          startedAt: DateTime.now(),
          assignedIpv4: outcome.publicIp,
          protocolLabel: _activeKind?.label ?? _session.protocolLabel,
        );
        _apply(VpnEvent.tunnelVerified(), outcome.message);
        _completeAttempt(const ConnectAttemptOutcome.connected());
      } else {
        // Not verified means not connected. Leaving the tunnel up while
        // claiming failure would be the worst outcome: the user would
        // believe they were protected while they were not.
        _fail('leak.unverified', outcome.message);
        await disconnect();
      }
    } finally {
      // Only the verification that still owns the gate may close it.
      // [cancel] clears the flag for the attempt it abandoned, and
      // letting that attempt's own verification clear it again would
      // release the gate while the *next* attempt was holding it — two
      // verifications running over one view.
      if (epoch == _attemptEpoch) {
        _verificationInFlight = false;
      }
      _emit();
    }
  }

  /// Starts the bounded wait for a single attempt to produce a handshake.
  ///
  /// Armed only once consent has been granted: the OS consent dialog may be
  /// open for as long as the user likes, and timing that out would report a
  /// refusal the user never made. From here on, though, nothing may sit in
  /// [VpnState.preparing], [VpnState.connecting] or [VpnState.reconnecting]
  /// indefinitely — the deadline, not the engine, decides when silence has
  /// become a failure.
  void _armConnectDeadline([Duration? budget]) {
    _connectDeadline?.cancel();
    final effective = budget ?? connectTimeout;
    _deadlineBudget = effective;
    _connectDeadline = Timer(effective, _onConnectDeadline);
  }

  /// Cancels the deadline, if one is armed.
  void _cancelConnectDeadline() {
    _connectDeadline?.cancel();
    _connectDeadline = null;
  }

  /// The deadline elapsed: the attempt neither failed nor produced a
  /// handshake in [connectTimeout].
  ///
  /// This is a real failure and is reported as one. Leaving the attempt in
  /// `connecting` forever — or worse, letting the engine's own silence be
  /// read as progress — is exactly what the deadline exists to prevent, so
  /// the tunnel is torn down as well as reported.
  void _onConnectDeadline() {
    _connectDeadline = null;
    if (_launching && _launchWatch.elapsed < launchGrace) {
      // The native side is still launching the tunnel (on Windows: the
      // administrator prompt may be open). Nothing has had a chance to
      // answer yet, so silence is not a verdict. The handshake clock
      // starts once the launch returns; [launchGrace] bounds the wait.
      return;
    }
    const attemptStates = {
      VpnState.preparing,
      VpnState.connecting,
      VpnState.reconnecting,
    };
    if (!attemptStates.contains(_current)) {
      return;
    }
    final seconds = (_deadlineBudget ?? connectTimeout).inSeconds;
    final detail = _lastHandshakeAt == null
        ? _tr('flowTimeoutNoHandshake')
        : _tr('flowTimeoutUnverified');
    _fail(
      'tunnel.timeout',
      _tr('flowTimeout', {'seconds': '$seconds', 'detail': detail}),
    );
    // The failure is already on screen; the teardown runs alongside it so
    // nothing is left running behind an error the user is reading.
    unawaited(_stopAfterFailure());
  }

  /// Stops the tunnel after the controller has finished with it — because a
  /// failure was reported, or because the attempt was abandoned.
  ///
  /// Best effort, and deliberately silent: in the first case the reason is
  /// already on screen, and in the second there is no reason to show — the
  /// user asked for the attempt to end. A stop that throws must not replace
  /// an original failure with a second, less useful one.
  ///
  /// The returned future is also remembered as [_lastStop], which is what
  /// the next attempt waits for before it starts anything.
  Future<void> _stopAfterFailure() {
    final stop = _teardownAfterFailure();
    _lastStop = stop;
    return stop;
  }

  /// The actual best-effort stop, silent by contract.
  Future<void> _teardownAfterFailure() async {
    try {
      await platform.stopTunnel();
    } on Object {
      // The attempt is already reported as failed; there is nothing the
      // user could do about a failed stop that this would change.
    }
  }

  void _apply(VpnEvent event, [String? message]) {
    final transition = VpnStateMachine.reduce(_current, event);
    if (!VpnStateMachine.allows(_current, transition.to)) {
      return;
    }
    _current = transition.to;
    // Leaving the transitional states ends the wait: verified, failed or
    // gone are all answers to the deadline, so it must not fire again
    // over a state that no longer claims to be in progress.
    if (!_current.isTransitioning) {
      _cancelConnectDeadline();
    }
    _statusMessage = message ?? transition.message ?? _statusMessage;
    _emit();
  }

  void _fail(String code, String message, {bool replayable = true}) {
    // The platform's captions are English-only. Where the app owns a
    // sentence for this code, that sentence leads; a code the problems
    // table does not carry (paths, engine's own words) keeps the native
    // message untouched.
    _errorMessage = _l10n.problem(code) ?? message;
    _errorCode = code;
    _canRetry = true;
    _failureReplayable = replayable;
    _apply(VpnEvent.failed(message), message);
    _completeAttempt(ConnectAttemptOutcome.failed(code, message));
  }

  /// Hands [outcome] to a caller awaiting [connectAndAwait], if any.
  ///
  /// The first outcome wins: a late failure arriving after the attempt was
  /// already judged must not rewrite an answer a walk has acted on.
  void _completeAttempt(ConnectAttemptOutcome outcome) {
    final completer = _attemptOutcome;
    if (completer != null && !completer.isCompleted) {
      completer.complete(outcome);
    }
  }

  /// Runs one connect attempt and reports how it ended.
  ///
  /// The future resolves when the attempt reaches a terminal outcome: a
  /// verified connection, or a failure. While an OS consent dialog is open
  /// it stays pending — an unanswered consent is not an outcome, and the
  /// person answering it decides how long that takes.
  ///
  /// A request that arrives while an attempt is still running replaces it
  /// rather than joining it: the user picked a different server, and
  /// queueing behind the old attempt would connect to the one they just
  /// left. The abandoned attempt's own outcome is completed as cancelled —
  /// deliberately not walkable — so an automatic walk stops instead of
  /// carrying on to the next relay after the user has said stop.
  Future<ConnectAttemptOutcome> connectAndAwait({
    VpnServer? server,
    VpnConfiguration? config,
    String? countryLabel,
    Duration? timeout,
  }) async {
    if (_current.isTransitioning) {
      await cancel();
      await _lastStop;
    }
    final pending = _attemptOutcome;
    if (pending != null && !pending.isCompleted) {
      return pending.future;
    }
    final outcome = Completer<ConnectAttemptOutcome>();
    _attemptOutcome = outcome;
    await connect(
      server: server,
      config: config,
      countryLabel: countryLabel,
      timeout: timeout,
    );
    if (!outcome.isCompleted && !_current.isTransitioning) {
      // The attempt ended without an event — a refusal at the consent
      // dialog, for example — so the state machine's own answer is the
      // outcome, rather than a future that never resolves.
      _completeAttempt(
        _current == VpnState.connected
            ? const ConnectAttemptOutcome.connected()
            : ConnectAttemptOutcome.failed(
                _errorCode ?? 'tunnel.failed',
                _errorMessage ?? _tr('flowTunnelFailed'),
              ),
      );
    }
    return outcome.future;
  }

  /// Shows, without touching the state, that an automatic attempt has
  /// moved on to another server.
  ///
  /// The status line is the only honest place for this: the attempt is
  /// still `connecting`, and inventing a state for the walk would either
  /// hide it or claim something the machine never entered.
  void reportWalkProgress(String message) {
    _statusMessage = message;
    _emit();
  }

  /// Replaces the last per-server failure of a multi-server attempt with
  /// an honest summary of what was tried.
  ///
  /// Used only when the walk ran out of servers rather than when a server
  /// produced a diagnosis: "none of five answered" and "this one refused
  /// authentication" need different next actions, and the summary must
  /// never bury the second one.
  void reportWalkExhausted({required int tried, required String message}) {
    _errorCode = 'tunnel.no_relay_reached';
    _errorMessage = message;
    _canRetry = true;
    // Nothing single to replay: a retry must run selection again, not
    // repeat the last server of a walk that already proved silent.
    _failureReplayable = false;
    _statusMessage = _stateStatusLabel();
    _emit();
  }

  /// Reports that a connection could not even be attempted.
  ///
  /// This is distinct from a tunnel failure: nothing was tried, so it must
  /// not be reported as "connecting failed" or leave the UI spinning. The
  /// state machine is given a `noServerAvailable` event so the button
  /// returns to a state the user can act on.
  ///
  /// The status line gets a short state label and [message] goes to the
  /// error card, which carries the retry action. Printing the same sentence
  /// in both places would read as two separate problems.
  ///
  /// [message] must be user-facing and free of secrets.
  void reportSelectionFailure(String message) {
    if (_current.isTransitioning) {
      return;
    }
    _errorCode = 'selection.failed';
    _errorMessage = message;
    _canRetry = true;
    _failureReplayable = false;
    // The state's own label, not the explanation: the explanation is
    // already on screen in the error card below it.
    _statusMessage = _stateStatusLabel();
    _apply(VpnEvent.noServerAvailable(message));
  }

  /// Connects to [server] using an already-validated [config].
  ///
  /// The order of the first few lines is the contract, not an accident:
  /// record the attempt (so a retry can replay *this* attempt), then ask the
  /// operating system for consent, and only then build anything. Consent
  /// arriving after `startTunnel` would mean the tunnel had been started on
  /// a permission the app did not have.
  ///
  /// [timeout] bounds this attempt, falling back to [connectTimeout]. A
  /// shorter bound is how an automatic walk spends its per-server budget
  /// without changing what a single explicit attempt gets.
  Future<void> connect({
    VpnServer? server,
    VpnConfiguration? config,
    String? countryLabel,
    Duration? timeout,
  }) async {
    // A previous failure may still be tearing its tunnel down. Waiting
    // for it here is what lets a walk start its next attempt cleanly
    // instead of racing the platform's own stop.
    await _lastStop;
    if (_current.isTransitioning) {
      // A connect request while one is in flight is a cancellation, not
      // a duplicate: the user pressed the control again or chose a
      // different server, and being ignored is the one outcome they
      // cannot act on. Only one tunnel exists, so the one running is
      // stopped before anything new is asked for.
      await cancel();
    }
    await _awaitSettled();
    if (_current.isConnected) {
      // The state machine treats "connect" while connected as a request
      // to bring the current tunnel down first. Honouring it here means
      // the new attempt starts from `disconnected` instead of racing a
      // live tunnel that nobody has stopped.
      await disconnect();
    }
    if (_current.isTransitioning) {
      // Teardown did not finish: the platform is still answering.
      // Starting on top of it is how a platform ends up racing its own
      // engine, and the attempt that is already on its way down would
      // have nowhere to go.
      //
      // Nothing was started, so anyone waiting on this request has to
      // be told so. Returning quietly would leave [connectAndAwait]
      // waiting for an attempt that does not exist — and its
      // completer, never completed, is what every later call would
      // have queued behind.
      _completeAttempt(
        ConnectAttemptOutcome.failed(
          'tunnel.failed',
          _tr('flowStillShuttingDown'),
        ),
      );
      return;
    }
    // Claimed after every path that could abandon a previous attempt, so
    // this attempt's continuations are the only ones still believed from
    // here until the next claim or cancellation.
    final epoch = ++_attemptEpoch;
    final target = server;
    final tunnelConfig = config;
    if (target == null || tunnelConfig == null) {
      // Nothing to connect to. This is a selection problem, not a tunnel
      // problem, so it reports as one rather than as a failure.
      reportSelectionFailure(_tr('selNoneSelected'));
      return;
    }

    // The attempt is recorded before anything can fail, because `retry`
    // replays exactly this server and configuration rather than starting
    // from an empty state machine.
    _lastServer = target;
    _lastConfig = tunnelConfig;
    _lastCountryLabel = countryLabel;
    _activeKind = tunnelConfig.kind;
    _selectedLabel = countryLabel?.trim().isNotEmpty == true
        ? countryLabel!.trim()
        : target.hostname;
    _failureReplayable = false;
    // A new attempt retires the previous attempt's error: leaving it on
    // screen would show a failure card beside a live session, which is
    // exactly what one live run produced — attempt 1's leak refusal
    // still displayed while attempt 2 was connected with traffic.
    _errorMessage = null;
    _errorCode = null;
    _canRetry = false;

    if (!await _ensurePermission(epoch)) {
      return;
    }
    if (epoch != _attemptEpoch) {
      // Abandoned while consent was being asked for. The OS dialog's
      // "OK" must not resurrect an attempt the user already stopped:
      // [VpnStateMachine] would drop the grant, and starting the tunnel
      // here would start it with no state to describe it.
      return;
    }
    // Consent is in hand: the attempt is now bounded. Nothing between
    // here and the first handshake may wait forever.
    _attemptBudget = timeout ?? connectTimeout;
    _armConnectDeadline(_attemptBudget);
    _apply(VpnEvent.connectRequested(), _tr('flowPreparing'));
    final preflightWatch = Stopwatch()..start();
    _ipBeforeTunnel = await _leakCheck.currentIp();
    developer.log(
      'phase=preflight_exit_ip duration_ms=${preflightWatch.elapsedMilliseconds} '
      'baseline_available=${_ipBeforeTunnel != null}',
      name: 'phantrix.connection',
    );
    if (epoch != _attemptEpoch) {
      // Superseded during the preflight probe. The address it read
      // belongs to the attempt that has since been abandoned.
      return;
    }

    // The **effective** configuration, not the one the user supplied.
    //
    // This is the only place a configuration reaches the platform, so this
    // is the only place the full-tunnel repair can be applied. Sending
    // `tunnelConfig` directly would bring the interface up with only the
    // peer's listed prefixes routed through it while every other packet
    // left over the physical interface — the exact silent leak the repair
    // exists to prevent, and one the repair's own unit tests could not
    // catch because they never went through this call.
    final effective = tunnelConfig.effective;

    final startWatch = Stopwatch()..start();
    final tunnelRequest = TunnelRequest(
      configJson: TunnelJson.encode(effective),
      killSwitchMode: switch (settings.data.killSwitch) {
        KillSwitchMode.off => 'off',
        KillSwitchMode.automatic => 'automatic',
        KillSwitchMode.strict => 'strict',
      },
      dnsMode: switch (settings.data.dnsMode) {
        DnsMode.vpn => 'vpn',
        DnsMode.trusted => 'trusted',
        DnsMode.custom => 'custom',
      },
      customDns: settings.data.customDns,
      ipv6Mode: switch (settings.data.ipv6) {
        Ipv6Mode.preferTunnel => 'prefer_tunnel',
        Ipv6Mode.block => 'block',
        Ipv6Mode.allow => 'allow',
      },
      mtuOverride: settings.data.mtuOverride,
      serverId: target.id,
      countryLabel: countryLabel ?? target.countryCode,
      ovpnConfig: serializeOpenVpnProfile(
        effective,
        ipv6Mode: settings.data.ipv6,
      ),
    );
    // The handshake clock does not run while the native side is still
    // launching the tunnel — on Windows that includes the administrator
    // prompt, which lasts as long as the person takes to answer it.
    _launching = true;
    _launchWatch
      ..reset()
      ..start();
    final Result<void> result;
    _launchedEpoch = epoch;
    try {
      result = await platform.startTunnel(tunnelRequest);
    } finally {
      _launching = false;
      _launchWatch.stop();
    }
    if (epoch != _attemptEpoch) {
      // Superseded while the platform was launching. If no newer attempt
      // has claimed the platform since, this call is the last thing that
      // touched it, and the tunnel it may have brought up would be
      // running behind a view that now says "Disconnected" — so it is
      // stopped, silently, because the attempt it belonged to is already
      // abandoned and there is no failure left to report.
      if (_launchedEpoch == epoch) {
        unawaited(_stopAfterFailure());
      }
      return;
    }
    // Launched: the budget for the engine to answer starts now, not at
    // the moment consent was granted. The preflight address lookup and
    // the launch itself used to be paid out of it.
    if (_current == VpnState.preparing ||
        _current == VpnState.connecting ||
        _current == VpnState.reconnecting) {
      _armConnectDeadline(_attemptBudget);
    }
    developer.log(
      'phase=platform_start duration_ms=${startWatch.elapsedMilliseconds} '
      'success=${result.errorOrNull == null}',
      name: 'phantrix.connection',
    );
    if (result.errorOrNull != null) {
      final error = result.errorOrNull!;
      _fail(error.code, error.message);
    }
  }

  /// Asks the operating system for VPN consent and reports the answer as an
  /// explicit state.
  ///
  /// The request is entered as [VpnState.permissionRequired] *before* the
  /// platform is called, so a dialog the user stares at for a minute is
  /// visible as "permission needed" rather than as a tunnel that is
  /// mysteriously still preparing. A refusal becomes [VpnState.blocked] —
  /// never `preparing`, because nothing was prepared.
  ///
  /// Returns false when consent was refused, in which case the caller must
  /// not start anything. [epoch] is the attempt that asked; if a different
  /// one is current when the answer arrives, the answer belongs to an
  /// attempt the user has abandoned and both outcomes are dropped without
  /// writing anything into the view.
  Future<bool> _ensurePermission(int epoch) async {
    _apply(const VpnEvent.permissionRequested(), _tr('flowPermissionWaiting'));
    final granted = await platform.requestPermission();
    if (epoch != _attemptEpoch) {
      return false;
    }
    if (!granted) {
      _errorCode = 'permission.denied';
      _errorMessage = _tr('flowPermissionDeniedCard');
      _canRetry = true;
      // The attempt was recorded before consent was asked for, so a
      // retry asks again and then continues with the same server.
      _failureReplayable = _lastServer != null && _lastConfig != null;
      _apply(
        const VpnEvent.permissionMissing(
          'The operating system did not grant VPN permission.',
        ),
        _tr('flowPermissionNeeded'),
      );
      return false;
    }
    _apply(const VpnEvent.permissionGranted());
    return true;
  }

  /// Brings the tunnel down and completes the explicit teardown step.
  ///
  /// `disconnecting` is a state the user can see, and it ends here rather
  /// than whenever the platform happens to emit its next event: `stopTunnel`
  /// answering *is* the engine confirming the tunnel is gone.
  Future<void> disconnect() {
    final running = _teardownInFlight;
    if (running != null) {
      // Already coming down. Joining it rather than starting a second
      // teardown: two of them take turns clearing [_teardownRequested],
      // which is the flag that tells an arriving `idle` whether the stop
      // was asked for — and clearing it early would let a platform's own
      // stop look like a tunnel that died unasked.
      return running;
    }
    final teardown = _teardown().whenComplete(() => _teardownInFlight = null);
    _teardownInFlight = teardown;
    // Remembered so the next attempt — usually a replacement for the one
    // just cancelled — waits for this tunnel to be gone instead of racing
    // the platform's own stop.
    _lastStop = teardown;
    return teardown;
  }

  /// The teardown itself, running under [_teardownInFlight].
  Future<void> _teardown() async {
    // The reason a connection ended is cleared *before* the transition, and
    // only when the user asked for it. When the controller tears the tunnel
    // down itself because verification failed, the reason must survive:
    // clearing it here used to wipe the explanation the user needed.
    final userInitiated = _errorMessage == null;
    _cancelConnectDeadline();
    _teardownRequested = true;
    try {
      _apply(VpnEvent.disconnectRequested());
      await platform.stopTunnel();
      _session = ConnectionSession.none;
      _traffic = PlatformTraffic.empty;
      _lastHandshakeAt = null;
      _statusMessage = _tr('flowNotConnected');
      if (userInitiated) {
        _errorMessage = null;
        _errorCode = null;
        _canRetry = false;
      } else {
        // The verdict that started this teardown may still be forming: a
        // walk-ahead can post its diagnosis — including a retry offer —
        // while the stop request is in flight. Clearing the offer here
        // would land after that and delete it from under the report
        // (observed live: a walk-exhausted card whose button had been
        // switched off by the teardown finishing last). A teardown the
        // attempt neither asked for nor caused must leave the evidence
        // alone.
      }
      _apply(VpnEvent.disconnected());
    } finally {
      _teardownRequested = false;
    }
    _emit();
  }

  /// Abandons whatever is in flight and brings the tunnel down.
  ///
  /// This is the connect control's answer while an attempt is running, and
  /// what a change of server does before the next attempt starts. It is not
  /// a failure: nothing went wrong, so no error is recorded, no retry is
  /// offered, and no "walk to the next server" is triggered. The control
  /// returns to `Disconnected` rather than to an error card the user would
  /// have to dismiss for doing what they asked.
  Future<void> cancel() async {
    // Every continuation of the attempt in flight is invalidated first, so
    // a `startTunnel` still waiting on the platform wakes up knowing it
    // lost instead of reporting its result into the state of whatever
    // replaces it.
    _attemptEpoch++;
    final pending = _attemptOutcome;
    if (pending != null && !pending.isCompleted) {
      // A cancelled attempt is an outcome for whoever is waiting on it —
      // an automatic walk most of all, which must stop rather than dial
      // the next server after the user has said stop. `tunnel.cancelled`
      // is deliberately not walkable: the next relay is the answer to
      // "this one is silent", not to "I changed my mind".
      _completeAttempt(
        const ConnectAttemptOutcome.failed(
          'tunnel.cancelled',
          'The connection attempt was cancelled.',
        ),
      );
    }
    if (_current == VpnState.disconnecting) {
      // Already on its way down; let that finish rather than asking the
      // platform to tear the same tunnel down twice.
      await _lastStop;
      return;
    }
    if (!_current.isTransitioning && !_current.isConnected) {
      // Nothing running and no tunnel. Stopping here would only ask the
      // platform to tear down a tunnel that does not exist.
      return;
    }
    // The abandoned attempt's verification must stop holding the gate the
    // next attempt needs. It can no longer publish anything — the state it
    // re-checks after its I/O no longer describes an attempt — but leaving
    // the gate closed would skip the next attempt's verification, and an
    // unverified tunnel is never reported as connected.
    _verificationInFlight = false;
    await disconnect();
  }

  /// Waits for the machine to stop changing state before starting anything.
  ///
  /// [disconnect] publishes its own future as [_lastStop], so a teardown
  /// this controller began is already covered. The case it cannot cover is
  /// a teardown nobody here started: the platform reporting `disconnecting`
  /// on its own — the system reclaiming the tunnel, say — leaves the machine
  /// in `disconnecting` with no future to wait on and no local code that
  /// will finish it. The next view change is the only thing that case has
  /// to offer, so that is what this waits for instead of giving up and
  /// racing an engine that is still coming down.
  ///
  /// Bounded, because "still shutting down" can also mean the platform has
  /// gone quiet: a caller that times out goes on to report that the attempt
  /// was never started rather than waiting forever.
  Future<void> _awaitSettled() async {
    final deadline = DateTime.now().add(settleTimeout);
    while (_current.isTransitioning) {
      await _lastStop;
      if (!_current.isTransitioning) {
        return;
      }
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        return;
      }
      try {
        await _views.stream.first.timeout(remaining);
      } on TimeoutException {
        return;
      }
    }
  }

  /// Retries the last failure: the same attempt again when one exists,
  /// a fresh selection when there is none.
  ///
  /// [retrySelection] is the difference between those two. Restarting a
  /// tunnel that was never started — or re-selecting a server that is
  /// already selected — would both be lies about what is being retried, so
  /// the failure that was reported decides which one happens.
  Future<void> retry() async {
    final code = _errorCode;
    if (code == null) {
      return;
    }
    _errorMessage = null;
    _errorCode = null;
    _canRetry = false;

    // A recorded attempt (including one refused at the consent dialog) is
    // replayed exactly: same server, same configuration, same country —
    // consent being asked again is part of replaying it, not a special
    // case, because [connect] always asks first.
    final server = _lastServer;
    final config = _lastConfig;
    if (_failureReplayable && server != null && config != null) {
      _statusMessage = _tr('flowRetry');
      _emit();
      await connect(
        server: server,
        config: config,
        countryLabel: _lastCountryLabel,
      );
      return;
    }

    // Nothing ever reached the engine, so only a fresh discovery and
    // selection can produce a different outcome.
    final reselect = retrySelection;
    if (reselect != null) {
      _statusMessage = _tr('flowLookingForServer');
      _emit();
      await reselect();
      return;
    }

    // No attempt to replay and no way to reselect: say so rather than
    // appear to do something.
    reportSelectionFailure(_tr('selRetryNeedsSelection'));
  }

  void dispose() {
    _disposed = true;
    // A deadline armed by an attempt that is being torn down must not
    // outlive the controller: it would fire into a closed view stream.
    _cancelConnectDeadline();
    unawaited(_platformEvents?.cancel());
    unawaited(_views.close());
  }
}
