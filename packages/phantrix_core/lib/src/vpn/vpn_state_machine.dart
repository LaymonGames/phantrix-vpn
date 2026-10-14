/// The connection state machine.
///
/// This is deliberately exhaustive and explicit. The single most important
/// rule in the whole app is enforced here:
///
///   The state may only become [VpnState.connected] after the tunnel has
///   actually been established *and verified*. Nothing else may set it, and
///   the only way out of a terminal failure state is a new transition.
///
/// Anything the OS reports as "up" is [VpnState.connecting] until the engine
/// confirms the handshake and the tunnel address.
library;

/// The visible connection state.
///
/// The canonical happy path is linear and fully explicit:
///
///   `disconnected → permissionRequired → preparing → connecting
///    → connected → disconnecting → disconnected`
///
/// plus [VpnState.reconnecting] for a network change on a live tunnel, and
/// the failure states ([VpnState.error], [VpnState.blocked],
/// [VpnState.noServerAvailable]) as the ways out of any attempt that did
/// not work.
enum VpnState {
	/// No tunnel, nothing in progress.
	disconnected('Disconnected'),

	/// The operating system's VPN consent is being requested (or is needed).
	///
	/// Not a failure: it is the state the app is in while the platform's own
	/// permission dialog decides. Reached before [VpnState.preparing] so that a
	/// refusal is never reported as a tunnel that was started and failed.
	permissionRequired('Permission needed'),

	/// Writing the configuration, preparing the platform tunnel.
	preparing('Preparing'),

	/// Waiting for the platform to report the tunnel is up.
	connecting('Connecting'),

	/// Bringing up the tunnel, or recovering from a network change.
	reconnecting('Reconnecting'),

	/// The tunnel is up and has been verified.
	connected('Connected'),

	/// The tunnel is being torn down. The engine has been told to stop and
	/// has not yet confirmed it is gone.
	disconnecting('Disconnecting'),

	/// A failure the app can describe and recover from automatically.
	error('Error'),

	/// A failure the user must resolve (permission revoked, server gone).
	blocked('Needs attention'),

	/// The directory has no server we can use.
	noServerAvailable('No server available');

	const VpnState(this.label);

	final String label;

	/// True while a transition is in flight and the connect button should be
	/// disabled rather than showing "connect".
	///
	/// [VpnState.permissionRequired] and [VpnState.disconnecting] count:
	/// both are moments when a second connect request would either
	/// double-prompt for consent or race a teardown that has not finished.
	bool get isTransitioning =>
			this == VpnState.permissionRequired ||
			this == VpnState.preparing ||
			this == VpnState.connecting ||
			this == VpnState.reconnecting ||
			this == VpnState.disconnecting;

	bool get isConnected => this == VpnState.connected;

	bool get isTerminalFailure => this == VpnState.error || this == VpnState.blocked;

	/// What the big connect button should say.
	String get actionLabel => switch (this) {
		VpnState.disconnected => 'Connect',
		VpnState.permissionRequired => 'Permission needed',
		VpnState.preparing => 'Preparing…',
		VpnState.connecting => 'Connecting…',
		VpnState.reconnecting => 'Reconnecting…',
		VpnState.connected => 'Disconnect',
		VpnState.disconnecting => 'Disconnecting…',
		VpnState.error => 'Try again',
		VpnState.blocked => 'Needs attention',
		VpnState.noServerAvailable => 'No server available',
	};
}

/// A change the state machine must react to.
class VpnEvent {
	const VpnEvent(this.type, {this.detail, this.error});

	const VpnEvent.connectRequested()
		: type = VpnEventType.connectRequested,
		  detail = null,
		  error = null;

	const VpnEvent.prepareRequested()
		: type = VpnEventType.prepareRequested,
		  detail = null,
		  error = null;

	const VpnEvent.disconnectRequested()
		: type = VpnEventType.disconnectRequested,
		  detail = null,
		  error = null;

	/// The platform's VPN consent is being requested now.
	const VpnEvent.permissionRequested()
		: type = VpnEventType.permissionRequested,
		  detail = null,
		  error = null;

	/// The platform's VPN consent was granted; the tunnel may be built.
	const VpnEvent.permissionGranted()
		: type = VpnEventType.permissionGranted,
		  detail = null,
		  error = null;

	const VpnEvent.tunnelStarting()
		: type = VpnEventType.tunnelStarting,
		  detail = null,
		  error = null;

	const VpnEvent.tunnelUp()
		: type = VpnEventType.tunnelUp,
		  detail = null,
		  error = null;

	const VpnEvent.tunnelVerified()
		: type = VpnEventType.tunnelVerified,
		  detail = null,
		  error = null;

	const VpnEvent.networkChanged()
		: type = VpnEventType.networkChanged,
		  detail = null,
		  error = null;

	const VpnEvent.disconnected()
		: type = VpnEventType.disconnected,
		  detail = null,
		  error = null;

	final VpnEventType type;

	/// A short, non-secret description of what happened.
	final String? detail;

	/// The underlying error, when there was one.
	final Object? error;

	/// The tunnel failed. [reason] must be safe to show the user.
	const VpnEvent.failed(String reason, {Object? cause})
		: type = VpnEventType.failed,
		  detail = reason,
		  error = cause;

	const VpnEvent.permissionMissing(String reason)
		: type = VpnEventType.permissionMissing,
		  detail = reason,
		  error = null;

	const VpnEvent.noServerAvailable(String reason)
		: type = VpnEventType.noServerAvailable,
		  detail = reason,
		  error = null;
}

enum VpnEventType {
	prepareRequested,
	connectRequested,
	disconnectRequested,
	permissionRequested,
	permissionGranted,
	tunnelStarting,
	tunnelUp,
	tunnelVerified,
	failed,
	permissionMissing,
	noServerAvailable,
	networkChanged,
	disconnected,
}

/// A transition the state machine produced.
///
/// The transition is returned rather than applied, so the caller can perform
/// the side effect and only then confirm with [VpnEvent.tunnelVerified].
class VpnTransition {
	const VpnTransition(this.to, {this.effects = const [], this.message});

	final VpnState to;
	final List<VpnEffect> effects;
	final String? message;
}

/// A side effect the host must perform for a transition to complete.
enum VpnEffect {
	/// The host must write the configuration and start the platform tunnel.
	startTunnel,

	/// The host must tear the tunnel down and clean up routing.
	stopTunnel,

	/// The host must re-run discovery before trying again.
	refreshServers,

	/// The host must ask the user for the platform VPN permission.
	requestPermission,

	/// The host must wait for the network to come back.
	awaitNetwork,
}

/// The pure state machine.
///
/// Kept free of platform APIs so it can be exhaustively unit-tested.
class VpnStateMachine {
	const VpnStateMachine();

	static const Set<VpnState> _protectedStates = {
		VpnState.disconnected,
		VpnState.connected,
		VpnState.blocked,
	};

	/// Applies [event] while in [state].
	static VpnTransition reduce(VpnState state, VpnEvent event) {
		switch (event.type) {
			case VpnEventType.connectRequested:
				if (state.isConnected) {
					return const VpnTransition(VpnState.disconnected, effects: [VpnEffect.stopTunnel]);
				}
				if (state.isTransitioning) {
					return VpnTransition(state);
				}
				return const VpnTransition(
					VpnState.preparing,
					effects: [VpnEffect.refreshServers, VpnEffect.startTunnel],
				);

			case VpnEventType.prepareRequested:
				if (state.isTransitioning || state.isConnected) {
					return VpnTransition(state);
				}
				return const VpnTransition(VpnState.preparing);

			case VpnEventType.permissionRequested:
				// Consent owns the flow once it has been asked for: a second
				// request while one is in flight would either double-prompt
				// or race a teardown. Everything else may need consent.
				if (state.isConnected || state.isTransitioning) {
					return VpnTransition(state);
				}
				return const VpnTransition(
					VpnState.permissionRequired,
					effects: [VpnEffect.requestPermission],
				);

			case VpnEventType.permissionGranted:
				// The one path into preparing that starts from consent. Only
				// from [VpnState.permissionRequired]: a grant arriving after
				// the attempt was cancelled (state already back to idle) must
				// be dropped, or the OS dialog's "OK" would restart a tunnel
				// the user just tore down.
				if (state == VpnState.permissionRequired) {
					return const VpnTransition(
						VpnState.preparing,
						effects: [VpnEffect.startTunnel],
					);
				}
				return VpnTransition(state);

			case VpnEventType.tunnelStarting:
				if (state == VpnState.preparing) {
					return const VpnTransition(VpnState.connecting);
				}
				return VpnTransition(state);

			case VpnEventType.tunnelUp:
				// Arriving here is *not* proof: the tunnel is up, not verified.
				if (state == VpnState.connecting || state == VpnState.reconnecting) {
					return VpnTransition(state, message: 'Handshake complete, verifying…');
				}
				return VpnTransition(state);

			case VpnEventType.tunnelVerified:
				// The only path to connected.
				return const VpnTransition(VpnState.connected);

			case VpnEventType.disconnectRequested:
				// Anything still running goes through an explicit
				// `disconnecting` step, so the UI never claims "disconnected"
				// while the engine is being torn down. Idle and failure
				// states have nothing to tear down beyond the cleanup effect,
				// so they complete immediately.
				if (state == VpnState.permissionRequired ||
						state == VpnState.preparing ||
						state == VpnState.connecting ||
						state == VpnState.reconnecting ||
						state == VpnState.connected ||
						state == VpnState.disconnecting) {
					return const VpnTransition(VpnState.disconnecting, effects: [VpnEffect.stopTunnel]);
				}
				return const VpnTransition(VpnState.disconnected, effects: [VpnEffect.stopTunnel]);

			case VpnEventType.networkChanged:
				if (state != VpnState.connected) {
					return VpnTransition(state);
				}
				return const VpnTransition(
					VpnState.reconnecting,
					effects: [VpnEffect.awaitNetwork, VpnEffect.startTunnel],
				);

			case VpnEventType.failed:
				return VpnTransition(VpnState.error, message: event.detail);

			case VpnEventType.permissionMissing:
				return const VpnTransition(
					VpnState.blocked,
					effects: [VpnEffect.requestPermission],
				);

			case VpnEventType.noServerAvailable:
				return const VpnTransition(VpnState.noServerAvailable);

			case VpnEventType.disconnected:
				// A platform-reported disconnect must always be honoured, even
				// from `connected`. `connected` used to be in `_protectedStates`
				// for this branch, which meant that when the system reclaimed
				// the tunnel — permission revoked, interface lost, process
				// killed — the event was swallowed and the UI went on claiming
				// the user was protected. Idempotency for a redundant
				// *requested* disconnect is handled by `disconnectRequested`; a
				// report that the tunnel is gone is new information and wins.
				if (state == VpnState.connected) {
					return const VpnTransition(
						VpnState.disconnected,
						effects: [VpnEffect.stopTunnel],
					);
				}
				if (_protectedStates.contains(state)) {
					return VpnTransition(state);
				}
				return const VpnTransition(VpnState.disconnected, effects: [VpnEffect.stopTunnel]);
		}
	}

	/// Whether the transition from [from] to [to] is allowed.
	///
	/// Used by the host as a second guard: if the engine reports a state the
	/// machine would not have produced, it is rejected and logged.
	static bool allows(VpnState from, VpnState to) {
		if (from == to) {
			return true;
		}
		return switch (to) {
			// The tunnel must be explicitly verified.
			VpnState.connected => from == VpnState.connecting || from == VpnState.reconnecting,
			VpnState.connecting => from == VpnState.preparing,
			VpnState.preparing =>
				from == VpnState.disconnected ||
				from == VpnState.error ||
				from == VpnState.permissionRequired,
			// Consent is asked for before anything is built, so it is
			// reachable from every idle or failed state but never from a
			// live tunnel or one that is on its way down.
			VpnState.permissionRequired =>
				!from.isConnected && !from.isTransitioning,
			VpnState.reconnecting => from == VpnState.connected,
			// The explicit teardown step, entered only from states where
			// there is something to tear down.
			VpnState.disconnecting =>
				from == VpnState.connected ||
				from == VpnState.permissionRequired ||
				from == VpnState.preparing ||
				from == VpnState.connecting ||
				from == VpnState.reconnecting,
			// A failure must always be representable, including from
			// `connected`. This branch used to refuse it, which meant an engine
			// failure arriving while connected was silently dropped and the UI
			// kept claiming the user was protected. A tunnel that has failed
			// cannot be reported as connected, whatever the previous state was.
			VpnState.error => true,
			VpnState.blocked => true,
			// Reachable from idle, not just mid-attempt: the user presses
			// Connect with an empty directory, and the honest answer is "there
			// is nothing to connect to", not a silent no-op. Reachable from a
			// failed attempt too, when a retry finds the list has emptied.
			VpnState.noServerAvailable => from == VpnState.preparing ||
					from == VpnState.reconnecting ||
					from == VpnState.disconnected ||
					from == VpnState.error ||
					from == VpnState.blocked,
			VpnState.disconnected => true,
		};
	}
}
