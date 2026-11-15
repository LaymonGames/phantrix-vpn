/// How one connect attempt ended, for a caller that may try several.
///
/// Deliberately small: an automatic walk needs to know whether to move on,
/// and a diagnosis only says whether *this* server should be left behind.
class ConnectAttemptOutcome {
  const ConnectAttemptOutcome._({
    required this.connected,
    this.code,
    this.message,
  });

  /// The attempt was verified: handshake plus a changed exit address.
  const ConnectAttemptOutcome.connected() : this._(connected: true);

  /// The attempt failed with a platform or state-machine diagnosis.
  const ConnectAttemptOutcome.failed(String code, String message)
    : this._(connected: false, code: code, message: message);

  /// True when the attempt was verified; false when it failed.
  final bool connected;

  /// The failure code, or null on success.
  final String? code;

  /// The user-safe failure message, or null on success.
  final String? message;

  /// True when another server could plausibly succeed here.
  ///
  /// Silence qualifies: an attempt that died without a diagnosis may have
  /// died because *this* relay is unreachable, which says nothing about the
  /// next one.
  ///
  /// So does a failed exit-address check ([leak.unverified]'s
  /// `leak.*`). The comment history here treated that as a diagnosis of the
  /// attempt — "walking past it would bury it under identical retries" — but
  /// measuring it against live volunteer relays shows the opposite. A relay
  /// that completes the TLS handshake yet never carries traffic is a property
  /// of *that server*, not of the configuration or the consent that started
  /// it. When that happens the top-ranked candidates are usually fine and only
  /// this one is a black hole, so refusing to walk strands the user on a
  /// single bad relay while healthy ones sit ranked behind it. The next
  /// relay's own result is reported on its own turn, so nothing is buried.
  ///
  /// What stays non-walkable is a failure that belongs to the attempt as a
  /// whole and would recur identically on every server: a rejected
  /// configuration, a refused administrator prompt.
  ///
  /// When a walk ends on a `leak.*` outcome, the resolver also gives the relay
  /// that negotiated it one more attempt before reporting exhaustion — see
  /// `ConnectionResolver.resolveAndConnect`.
  ///
  /// A server's `ovpn.auth_failed` is deliberately walkable. The client here
  /// carries no credentials — the app has no username/password UI — so a
  /// relays-side authentication refusal can only have two causes: the relay's
  /// SoftEther layer demands credentials (VPN Gate accepts anonymous ones, but
  /// not every volunteer build honours that), or the relay is refusing
  /// sessions for its own regional/load reasons. Both are properties of *that
  /// relay*: the next one answers its own authentication question, and failing
  /// the walk on the first refuser would strand the user exactly where a
  /// healthy relay sat one rank below. Measured live: one US relay challenged
  /// while its neighbour completed the handshake untouched.
  ///
  /// The same reasoning covers the engine's own relay-facing failures:
  /// `ovpn.tls_failed` (the peer refused or dropped the TLS handshake),
  /// `ovpn.engine_exited` (the engine ended under a relay that stopped
  /// answering), and the generic `tunnel.failed` / `tunnel.start_failed` /
  /// `tunnel.launch_timeout` (an engine that never came up for this relay).
  /// Volunteer relays outside the busiest countries are few and frequently
  /// broken, so treating one such failure as a verdict on the whole country
  /// left every other relay in it unvisited.
  ///
  /// Split-tunnel failures split the same way. A router or kill-switch
  /// failure (`split.router_missing`, `kill_switch.failed`, …) belongs to the
  /// machine and recurs on every relay, so it stays terminal. A policy that
  /// could not be applied to *this* tunnel (`split.policy_rejected`,
  /// `split.route_failed`) may be a property of this adapter and is walked
  /// past: the next relay brings up its own adapter and its own address.
  ///
  /// Unknown codes stay terminal. Walking a failure whose cause is not known
  /// spends a full step per relay on something that may never change.
  bool get walkable => _relayScoped.contains(code) || _isLeak(code);

  static bool _isLeak(String? value) =>
      value != null && value.startsWith('leak.');

  /// Failures that describe the relay or its interface, not the attempt.
  static const Set<String> _relayScoped = {
    'tunnel.timeout',
    'tunnel.died',
    'tunnel.failed',
    'tunnel.start_failed',
    'tunnel.launch_timeout',
    'ovpn.auth_failed',
    'ovpn.tls_failed',
    'ovpn.engine_exited',
    'split.policy_rejected',
    'split.route_failed',
  };
}
