import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:phantrix_core/phantrix_core.dart';
import 'package:phantrix_platform/phantrix_platform.dart';

import 'package:phantrix/discovery/discovery_controller.dart';
import 'package:phantrix/net/app_http_fetcher.dart';
import 'package:phantrix/settings/settings_controller.dart';
import 'package:phantrix/vpn/connection_controller.dart';
import 'package:phantrix/vpn/connection_resolver.dart';
import 'package:phantrix/vpn/leak_check.dart';

/// A provider that serves a distinct configuration per server, so an attempt
/// can be told apart by the endpoint it carries.
class WalkProvider implements ServerProvider {
	WalkProvider({required this.servers, required this.configs});

	final List<VpnServer> servers;
	final Map<String, ProviderConfig> configs;

	@override
	String get id => 'walk';

	@override
	String get label => 'walk';

	@override
	ProviderCapabilities get capabilities => const ProviderCapabilities();

	@override
	bool get autoRefresh => true;

	@override
	String get trustDescription => 'test';

	@override
	HttpFetcher get fetcher => throw UnimplementedError('not used');

	@override
	Future<RefreshOutcome> refresh({bool force = false}) async => RefreshOutcome(
		servers: servers,
		usedCache: false,
		fetchedAt: DateTime(2026),
	);

	@override
	Future<ProviderConfig?> fetchConfig(String serverId) async => configs[serverId];
}

/// A genuinely parsed and validated WireGuard configuration for [host].
ProviderConfig wgConfigFor(String host) {
	final text = '''
[Interface]
PrivateKey = 02R31BtVMJe/5r8cMd8uRVf6DysDrWKFXxDlMdRDU6c=
Address = 10.8.0.2/32
DNS = 10.8.0.1

[Peer]
PublicKey = iGaPncC709q7zIxUD9OMJENN3dh+W40oQx0Lv7AStp8=
AllowedIPs = 0.0.0.0/0
Endpoint = $host:51820
''';
	final verdict = WgValidator.validate(WgParser.parse(text).valueOrNull!).valueOrNull!;
	return ProviderConfig(
		providerId: 'walk',
		rawText: text,
		validated: VpnConfiguration.wireGuard(verdict),
	);
}

VpnServer walkServer({
	required String id,
	required int latencyMs,
	String country = 'DE',
}) {
	final octet = id.codeUnits.fold<int>(0, (sum, c) => (sum + c) % 200) + 2;
	return VpnServer(
		id: id,
		hostname: '$id.example',
		hostAddress: '192.0.2.$octet',
		port: 51820,
		protocol: ProtocolKind.wireGuard,
		trustLevel: TrustLevel.projectVerified,
		countryCode: country,
		providerId: 'walk',
		status: ServerStatus.online,
		metrics: ServerMetrics(latencyMs: latencyMs),
	);
}

/// A bridge that scripts what each attempt does.
///
/// One script entry per `startTunnel` call, in order:
///  * `handshake` — reports a dated handshake the verifier can pass;
///  * `silent` — says nothing, so the deadline ends the attempt (the live
///    failure shape: an engine waiting on a relay that never answers);
///  * `authFailed` — reports a diagnosed platform failure.
class WalkBridge extends PhantrixPlatform {
	final events2 = StreamController<PlatformEvent>.broadcast();

	final List<String> script = <String>[];

	/// The `configJson` of every attempt, in the order they started.
	final List<String> startedTo = <String>[];

	/// Whether the scripted tunnel is currently up.
	///
	/// The exit-address mock reads this so an attempt's baseline is the
	/// pre-tunnel address and its verification read is the tunnel's — the
	/// one shape the verifier may honestly pass.
	bool tunnelUp = false;

	int stopCalls = 0;

	@override
	Stream<PlatformEvent> get events => events2.stream;

	@override
	Future<PlatformCapabilities> capabilities() async => PlatformCapabilities.web;

	@override
	Future<bool> requestPermission() async => true;

	@override
	Future<Result<void>> startTunnel(TunnelRequest request) async {
		startedTo.add(request.configJson);
		final step = startedTo.length <= script.length
				? script[startedTo.length - 1]
				: 'silent';
		switch (step) {
			case 'handshake':
				tunnelUp = true;
				events2.add(_evt(PlatformTunnelState.preparing));
				events2.add(_evt(PlatformTunnelState.connecting));
				events2.add(_evt(PlatformTunnelState.established));
				events2.add(
					PlatformEvent(
						state: PlatformTunnelState.handshaked,
						traffic: const PlatformTraffic(rxBytes: 4096, txBytes: 1024),
						lastHandshakeAtMillis:
								DateTime.now().millisecondsSinceEpoch,
					),
				);
			case 'authFailed':
				events2.add(
					PlatformEvent(
						state: PlatformTunnelState.failed,
						traffic: PlatformTraffic.empty,
						errorCode: 'ovpn.auth_failed',
						message: 'Authentication rejected by the server.',
					),
				);
			case 'silent':
				break;
		}
		return const Ok(null);
	}

	PlatformEvent _evt(PlatformTunnelState state) =>
			PlatformEvent(state: state, traffic: PlatformTraffic.empty);

	@override
	Future<Result<void>> stopTunnel() async {
		stopCalls++;
		tunnelUp = false;
		return const Ok(null);
	}

	@override
	void dispose() {
		events2.close();
	}
}

/// Waits until [controller] reports connected, or fails the test with the
/// controller's own diagnosis, which is the useful part.
Future<void> waitForConnected(
	ConnectionController controller, {
	Duration timeout = const Duration(seconds: 5),
}) async {
	final deadline = DateTime.now().add(timeout);
	while (!controller.currentView.state.isConnected) {
		if (DateTime.now().isAfter(deadline)) {
			final view = controller.currentView;
			fail(
				'the tunnel never became connected.\n'
				'  state:    ${view.state.name}\n'
				'  status:   ${view.statusMessage}\n'
				'  error:    ${view.errorCode ?? "-"} / ${view.errorMessage ?? "-"}',
			);
		}
		await Future<void>.delayed(const Duration(milliseconds: 5));
	}
}

/// Waits until [controller] reports a failure code, or fails the test.
Future<void> waitForError(
	ConnectionController controller, {
	Duration timeout = const Duration(seconds: 5),
}) async {
	final deadline = DateTime.now().add(timeout);
	while (controller.currentView.errorCode == null) {
		if (DateTime.now().isAfter(deadline)) {
			final view = controller.currentView;
			fail(
				'no failure was reported.\n'
				'  state:    ${view.state.name}\n'
				'  status:   ${view.statusMessage}',
			);
		}
		await Future<void>.delayed(const Duration(milliseconds: 5));
	}
}

/// The rule these tests protect: an automatic connect must not bet the whole
/// attempt on one relay that never answers.
///
/// The ranking is built from measurements taken elsewhere — the provider's
/// ping and uptime columns — so the top-ranked server can be a black hole
/// from this network. A silent server costs one bounded step; a *diagnosed*
/// failure stops the walk instead of being buried under identical retries.
void main() {
	const stepTimeout = Duration(milliseconds: 150);

	Future<
		({ConnectionController controller, ConnectionResolver resolver, WalkBridge bridge})
	> build({
		required List<String> script,
		int walkDepth = 3,
	}) async {
		final servers = [
			walkServer(id: 'a', latencyMs: 5),
			walkServer(id: 'b', latencyMs: 20),
			walkServer(id: 'c', latencyMs: 90),
		];
		final bridge = WalkBridge()..script.addAll(script);
		addTearDown(bridge.dispose);
		// The exit address is the tunnel's while the scripted tunnel is up,
		// and the physical interface's otherwise — the one shape under which
		// "connected" is an honest word. `connect` reads the baseline itself,
		// before the platform is asked for the tunnel, so this ordering is
		// what makes the check mean something.
		final controller = ConnectionController(
			platform: bridge,
			settings: SettingsController(
				SettingsController().data.copyWith(privacyNoticeAccepted: true),
			),
			leakCheck: LeakCheck(
				fetcher: AppHttpFetcher(
					client: MockClient(
						(_) async => http.Response(
							bridge.tunnelUp
									? '{"ip":"203.0.113.9"}'
									: '{"ip":"198.51.100.4"}',
							200,
						),
					),
				),
				wait: (_) async {},
			),
			// Also short here, so the never-walked explicit attempt stays
			// fast without touching what it is allowed to do.
			connectTimeout: stepTimeout,
		);
		addTearDown(controller.dispose);
		await pumpEventQueue();
		final resolver = ConnectionResolver(
			discovery: DiscoveryController(
				providers: [
					WalkProvider(
						servers: servers,
						configs: {
							for (final server in servers)
								server.id: wgConfigFor(server.hostAddress!),
						},
					),
				],
			),
			walkDepth: walkDepth,
			walkStepTimeout: stepTimeout,
		);
		await resolver.discovery.refresh();
		return (controller: controller, resolver: resolver, bridge: bridge);
	}

	group('an automatic connect walks past a silent server', () {
		test('the next ranked server is tried, and it connects', () async {
			final harness = await build(script: ['silent', 'handshake']);

			await harness.resolver.resolveAndConnect(
				const SelectionRequest(mode: SelectionMode.recommended),
				connection: harness.controller,
			);
			await waitForConnected(harness.controller);

			// Two attempts, in ranking order: best first, then next.
			expect(harness.bridge.startedTo, hasLength(2));
			expect(harness.bridge.startedTo.first, contains('192.0.2.'));
			expect(
				harness.bridge.startedTo.last,
				isNot(equals(harness.bridge.startedTo.first)),
				reason: 'the walk must move to a different server',
			);
			expect(harness.controller.currentView.state.isConnected, isTrue);
			expect(harness.bridge.stopCalls, 1, reason: 'the silent attempt was torn down');
		});

		test('when every server is silent the failure names the walk, and a retry reselects',
			() async {
			final harness = await build(
				script: ['silent', 'silent', 'silent'],
				walkDepth: 3,
			);
			var reselected = 0;
			harness.controller.retrySelection = () async => reselected++;

			await harness.resolver.resolveAndConnect(
				const SelectionRequest(mode: SelectionMode.recommended),
				connection: harness.controller,
			);

			final view = harness.controller.currentView;
			expect(harness.bridge.startedTo, hasLength(3));
			expect(view.state.isConnected, isFalse);
			expect(view.errorCode, 'tunnel.no_relay_reached');
			expect(view.errorMessage, contains('3'));
			expect(view.canRetry, isTrue);

			await harness.controller.retry();
			expect(reselected, 1, reason: 'a finished walk must run selection again');
			expect(
				harness.bridge.startedTo,
				hasLength(3),
				reason: 'retry must not replay a server the walk already proved silent',
			);
		});

		test('a diagnosed failure ends the walk instead of being buried', () async {
			final harness = await build(script: ['authFailed']);

			await harness.resolver.resolveAndConnect(
				const SelectionRequest(mode: SelectionMode.recommended),
				connection: harness.controller,
			);
			await pumpEventQueue();

			// The diagnosis applies to the attempt, not only to this server's
			// reachability, so the walk must stop on it and keep it visible.
			expect(harness.bridge.startedTo, hasLength(1));
			final view = harness.controller.currentView;
			expect(view.state.isConnected, isFalse);
			expect(view.errorCode, 'ovpn.auth_failed');
		});

		test('a chosen server is never silently substituted', () async {
			final harness = await build(script: ['silent']);

			await harness.resolver.resolveAndConnect(
				const SelectionRequest(
					mode: SelectionMode.specificServer,
					serverId: 'a',
				),
				connection: harness.controller,
			);
			await waitForError(harness.controller);

			expect(
				harness.bridge.startedTo,
				hasLength(1),
				reason: 'the user asked for this server, not for the ranking',
			);
			expect(harness.controller.currentView.errorCode, 'tunnel.timeout');
		});
	});

	group('a cancelled attempt ends the walk', () {
		test('the next ranked relay is not dialled after the user stops', () async {
			// The dangerous reading of a cancellation is the one a walk already
			// knows: an attempt that produced no outcome because the relay was
			// silent. Read that way, cancelling would send the walk on to the
			// next server — the app connecting to servers after the press.
			final harness = await build(
				script: ['silent', 'handshake', 'handshake'],
			);

			unawaited(harness.resolver.resolveAndConnect(
				const SelectionRequest(mode: SelectionMode.recommended),
				connection: harness.controller,
			));
			final deadline = DateTime.now().add(const Duration(seconds: 5));
			while (harness.bridge.startedTo.isEmpty &&
					DateTime.now().isBefore(deadline)) {
				await Future<void>.delayed(const Duration(milliseconds: 5));
			}
			expect(
				harness.bridge.startedTo,
				hasLength(1),
				reason: 'the walk must be on a server before stopping it means anything',
			);

			await harness.controller.cancel();
			await pumpEventQueue();

			// Several step budgets, during which a walk that had not stopped
			// would have dialled every remaining server.
			await Future<void>.delayed(const Duration(milliseconds: 400));

			expect(
				harness.bridge.startedTo,
				hasLength(1),
				reason: 'the walk stopped instead of moving on',
			);
			final view = harness.controller.currentView;
			expect(view.state, VpnState.disconnected);
			expect(view.errorCode, isNull, reason: 'a cancellation is not a failure');
			expect(view.errorMessage, isNull);
			expect(view.canRetry, isFalse);
		});
	});
}
