import 'package:phantrix_core/src/vpn/vpn_state_machine.dart';
import 'package:test/test.dart';

void main() {
	group('VpnStateMachine', () {
		test('a full connect path reaches connected only after verification', () {
			var state = VpnState.disconnected;
			var t = VpnStateMachine.reduce(state, const VpnEvent.connectRequested());
			expect(t.to, VpnState.preparing);
			expect(t.effects, contains(VpnEffect.startTunnel));

			state = t.to;
			t = VpnStateMachine.reduce(state, const VpnEvent.tunnelStarting());
			expect(t.to, VpnState.connecting);

			state = t.to;
			// The tunnel being "up" is not enough.
			t = VpnStateMachine.reduce(state, const VpnEvent.tunnelUp());
			expect(t.to, VpnState.connecting);
			expect(t.message, isNotNull);

			state = t.to;
			t = VpnStateMachine.reduce(state, const VpnEvent.tunnelVerified());
			expect(t.to, VpnState.connected);
		});

		test('consent is asked for before anything is built', () {
			// idle → permissionRequired → preparing is the explicit path the
			// app follows: the OS dialog gets its own state, so a refusal is
			// never reported as a tunnel that started and failed.
			var state = VpnState.disconnected;
			var t = VpnStateMachine.reduce(state, const VpnEvent.permissionRequested());
			expect(t.to, VpnState.permissionRequired);
			expect(t.effects, contains(VpnEffect.requestPermission));
			expect(VpnStateMachine.allows(state, t.to), isTrue);

			state = t.to;
			t = VpnStateMachine.reduce(state, const VpnEvent.permissionGranted());
			expect(t.to, VpnState.preparing);
			expect(t.effects, contains(VpnEffect.startTunnel));
			expect(VpnStateMachine.allows(VpnState.permissionRequired, t.to), isTrue);
		});

		test('a refused consent blocks rather than starting a tunnel', () {
			final t = VpnStateMachine.reduce(
				VpnState.permissionRequired,
				const VpnEvent.permissionMissing('user declined'),
			);
			expect(t.to, VpnState.blocked);
		});

		test('consent is never re-requested while one is in flight', () {
			final t = VpnStateMachine.reduce(
				VpnState.permissionRequired,
				const VpnEvent.permissionRequested(),
			);
			expect(t.to, VpnState.permissionRequired);
		});

		test('consent cannot be asked for while tearing down or connected', () {
			expect(
				VpnStateMachine.reduce(
					VpnState.disconnecting,
					const VpnEvent.permissionRequested(),
				).to,
				VpnState.disconnecting,
			);
			expect(
				VpnStateMachine.reduce(
					VpnState.connected,
					const VpnEvent.permissionRequested(),
				).to,
				VpnState.connected,
			);
		});

		test('the machine refuses to jump straight to connected', () {
			expect(VpnStateMachine.allows(VpnState.preparing, VpnState.connected), isFalse);
			expect(VpnStateMachine.allows(VpnState.disconnected, VpnState.connected), isFalse);
			expect(VpnStateMachine.allows(VpnState.error, VpnState.connected), isFalse);
		});

		test('connected only arrives from connecting or reconnecting', () {
			expect(VpnStateMachine.allows(VpnState.connecting, VpnState.connected), isTrue);
			expect(VpnStateMachine.allows(VpnState.reconnecting, VpnState.connected), isTrue);
		});

		test('a failure is reported, not swallowed', () {
			final t = VpnStateMachine.reduce(
				VpnState.connecting,
				const VpnEvent.failed('Handshake timed out'),
			);
			expect(t.to, VpnState.error);
			expect(t.message, 'Handshake timed out');
		});

		test('a missing permission blocks with an explicit action', () {
			final t = VpnStateMachine.reduce(
				VpnState.preparing,
				const VpnEvent.permissionMissing('VpnService permission not granted'),
			);
			expect(t.to, VpnState.blocked);
			expect(t.effects, contains(VpnEffect.requestPermission));
		});

		test('a network change while connected reconnects rather than dropping', () {
			final t = VpnStateMachine.reduce(VpnState.connected, const VpnEvent.networkChanged());
			expect(t.to, VpnState.reconnecting);
			expect(t.effects, contains(VpnEffect.startTunnel));
		});

		test('a network change while disconnected does nothing', () {
			final t = VpnStateMachine.reduce(
				VpnState.disconnected,
				const VpnEvent.networkChanged(),
			);
			expect(t.to, VpnState.disconnected);
		});

		test('disconnect always requests a teardown', () {
			// Every state must reach the engine's stop path: the effect is
			// unconditional, and the target is the explicit `disconnecting`
			// step while something is still running, or `disconnected`
			// directly when there is nothing to bring down.
			for (final state in VpnState.values) {
				final t = VpnStateMachine.reduce(state, const VpnEvent.disconnectRequested());
				expect(t.effects, contains(VpnEffect.stopTunnel), reason: 'from $state');
				final active = state == VpnState.permissionRequired ||
						state == VpnState.preparing ||
						state == VpnState.connecting ||
						state == VpnState.reconnecting ||
						state == VpnState.connected ||
						state == VpnState.disconnecting;
				expect(
					t.to,
					active ? VpnState.disconnecting : VpnState.disconnected,
					reason: 'from $state',
				);
				expect(VpnStateMachine.allows(state, t.to), isTrue, reason: 'from $state');
			}
		});

		test('disconnecting completes when the engine confirms it is gone', () {
			final t = VpnStateMachine.reduce(
				VpnState.disconnecting,
				const VpnEvent.disconnected(),
			);
			expect(t.to, VpnState.disconnected);
		});

		test('a repeated disconnect while already tearing down stays put', () {
			final t = VpnStateMachine.reduce(
				VpnState.disconnecting,
				const VpnEvent.disconnectRequested(),
			);
			expect(t.to, VpnState.disconnecting);
			expect(t.effects, contains(VpnEffect.stopTunnel));
		});

		test('the teardown step cannot be skipped from a live tunnel', () {
			// `connected → disconnected` is only reachable through a
			// platform report; a *requested* disconnect passes through
			// `disconnecting` so the UI never claims the tunnel is gone
			// before the engine says so.
			expect(
				VpnStateMachine.allows(VpnState.connected, VpnState.disconnecting),
				isTrue,
			);
			expect(
				VpnStateMachine.allows(VpnState.disconnecting, VpnState.disconnected),
				isTrue,
			);
		});

		test('an unexpected drop while transitioning goes to disconnected, not connected', () {
			final t = VpnStateMachine.reduce(
				VpnState.connecting,
				const VpnEvent.disconnected(),
			);
			expect(t.to, VpnState.disconnected);
		});

		test('no server available is reachable from preparing', () {
			final t = VpnStateMachine.reduce(
				VpnState.preparing,
				const VpnEvent.noServerAvailable('No usable server in the cached list'),
			);
			expect(t.to, VpnState.noServerAvailable);
		});

	test('no server is reachable from idle, which is the common case', () {
		// Pressing Connect with an empty directory must produce an honest
		// state, not a silent no-op. This transition used to be rejected, so
		// the user saw nothing at all.
		final t = VpnStateMachine.reduce(
			VpnState.disconnected,
			const VpnEvent.noServerAvailable('The server list is empty'),
		);
		expect(t.to, VpnState.noServerAvailable);
		expect(VpnStateMachine.allows(VpnState.disconnected, t.to), isTrue);
	});

	test('no server is reachable again after a previous failure', () {
		final t = VpnStateMachine.reduce(
			VpnState.error,
			const VpnEvent.noServerAvailable('The list emptied since the retry'),
		);
		expect(t.to, VpnState.noServerAvailable);
		expect(VpnStateMachine.allows(VpnState.error, t.to), isTrue);
	});

	test('no server is never reported from a live tunnel', () {
		// A connected tunnel cannot discover it has no server; that would
		// be a lie about a running connection.
		expect(
			VpnStateMachine.allows(VpnState.connected, VpnState.noServerAvailable),
			isFalse,
		);
	});

	test('the user can always leave no-server and try again', () {
		expect(
			VpnStateMachine.allows(VpnState.noServerAvailable, VpnState.disconnected),
			isTrue,
		);
		final t = VpnStateMachine.reduce(
			VpnState.noServerAvailable,
			const VpnEvent.connectRequested(),
		);
		expect(t.to, isNot(VpnState.noServerAvailable));
	});

		test('connect while already connected disconnects', () {
			final t = VpnStateMachine.reduce(
				VpnState.connected,
				const VpnEvent.connectRequested(),
			);
			expect(t.to, VpnState.disconnected);
		});

		test('a second connect while transitioning is ignored', () {
			final t = VpnStateMachine.reduce(
				VpnState.connecting,
				const VpnEvent.connectRequested(),
			);
			expect(t.to, VpnState.connecting);
		});

		test('every state has a distinct action label', () {
			final labels = VpnState.values.map((s) => s.actionLabel).toSet();
			expect(labels.length, VpnState.values.length);
		});

		test('states that look connected are exactly one state', () {
			final connected = VpnState.values.where((s) => s.isConnected).toList();
			expect(connected, [VpnState.connected]);
		});

		test('a failure from connected is representable, so it cannot look like '
			'success', () {
			// The assertion here used to be `isFalse`, which meant the engine
			// reporting a failure while connected was silently dropped and the
			// UI went on claiming the user was protected. The intent behind the
			// original test name is the opposite of what it asserted: a failure
			// must never be able to leave the app looking connected. That is
			// only guaranteed if the error state is reachable from connected.
			expect(VpnStateMachine.allows(VpnState.connected, VpnState.error), isTrue);
			expect(
				VpnStateMachine.reduce(VpnState.connected, const VpnEvent.failed('gone'))
					.to,
				VpnState.error,
			);
		});

		test('a platform-reported disconnect from connected is honoured', () {
			// The system reclaiming the tunnel — permission revoked, interface
			// lost, process killed — must move the app out of connected.
			expect(
				VpnStateMachine.reduce(
					VpnState.connected,
					const VpnEvent.disconnected(),
				).to,
				VpnState.disconnected,
			);
		});

		test('a redundant disconnect from disconnected stays put', () {
			// Idempotency is still wanted for a *requested* disconnect; it is
			// only a platform report that must always win.
			expect(
				VpnStateMachine.reduce(
					VpnState.disconnected,
					const VpnEvent.disconnected(),
				).to,
				VpnState.disconnected,
			);
		});
	});
}
