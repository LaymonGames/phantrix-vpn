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
import 'package:phantrix/vpn/relay_probe.dart';

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
  Future<ProviderConfig?> fetchConfig(String serverId) async =>
      configs[serverId];
}

int _octetFor(String id) => (id.codeUnits.fold<int>(0, (sum, c) => sum + c) % 200) + 2;

VpnServer walkServer({
  required String id,
  required int latencyMs,
  String country = 'DE',
  ServerStatus status = ServerStatus.online,
}) {
  final octet = _octetFor(id);
  return VpnServer(
    id: id,
    hostname: '$id.example',
    hostAddress: '192.0.2.$octet',
    port: 1194,
    protocol: ProtocolKind.openVpn,
    trustLevel: TrustLevel.projectVerified,
    countryCode: country,
    providerId: 'walk',
    status: status,
    metrics: ServerMetrics(latencyMs: latencyMs),
  );
}

/// An OpenVPN TCP profile pointing at [host].
///
/// TCP on purpose: the reachability probe asks whether anything answers on
/// the remote, so a profile whose remote is a UDP endpoint would never be
/// probed and a test that wants the probe to run needs this shape.
ProviderConfig ovpnConfigFor(String host) {
  final text =
      '''
client
dev tun
proto tcp
remote $host 1194
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
verb 3
<ca>
-----BEGIN CERTIFICATE-----
MIIFazCCA1OgAwIBAgIRAIIQz7DSQONZRGPgu2OCiwAwDQYJKoZIhvcNAQELBQAw
TzELMAkGA1UEBhMCVVMxKTAnBgNVBAoTIEludGVybmV0IFNlY3VyaXR5IFJlc2Vh
-----END CERTIFICATE-----
</ca>
''';
  final parsed = OvpnParser.parse(text).valueOrNull!;
  final verdict = OvpnValidator.validate(parsed).valueOrNull!;
  return ProviderConfig(
    providerId: 'walk',
    rawText: text,
    validated: VpnConfiguration.openVpn(verdict),
  );
}

/// Capabilities of a host that can start OpenVPN, which is what Windows
/// reports once the bundled engine is present.
///
/// The default web profile says `openVpn: false`, and an OpenVPN server on a
/// host that cannot run it is filtered out before the walk starts.
const ovpnCapabilities = PlatformCapabilities(
  platformName: 'test',
  supportsKillSwitch: false,
  supportsIpv6Blocking: false,
  supportsVpnProvidedDns: false,
  supportsPerAppSplitTunnelling: false,
  supportsLanBypass: false,
  supportsAlwaysOn: false,
  supportsTray: false,
  supportsBootStart: false,
  openVpn: true,
);

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

  /// What this host reports it can do: OpenVPN, which is what Windows reports
  /// once the bundled engine is present.
  PlatformCapabilities reported = ovpnCapabilities;

  @override
  Stream<PlatformEvent> get events => events2.stream;

  @override
  Future<PlatformCapabilities> capabilities() async => reported;

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
            lastHandshakeAtMillis: DateTime.now().millisecondsSinceEpoch,
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
      case 'configRejected':
        events2.add(
          PlatformEvent(
            state: PlatformTunnelState.failed,
            traffic: PlatformTraffic.empty,
            errorCode: 'ovpn.config_rejected',
            message: 'The server asked for something this build will not do.',
          ),
        );
      case 'leakFail':
        // The engine negotiated — dated handshake and all — but the tunnel
        // never proved it carries traffic: with `tunnelUp` staying false,
        // the exit-address mock reports the pre-tunnel address, so
        // verification finds the physical route unchanged and fails. This
        // is the live shape the engine archive captured: a relay reaching
        // `Initialization Sequence Completed` while the exit check could
        // not confirm it, the walk walking past, and the final report
        // claiming no relay had been reached.
        events2.add(_evt(PlatformTunnelState.preparing));
        events2.add(_evt(PlatformTunnelState.connecting));
        events2.add(_evt(PlatformTunnelState.established));
        events2.add(
          PlatformEvent(
            state: PlatformTunnelState.handshaked,
            traffic: const PlatformTraffic(rxBytes: 4096, txBytes: 1024),
            lastHandshakeAtMillis: DateTime.now().millisecondsSinceEpoch,
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
    ({
      ConnectionController controller,
      ConnectionResolver resolver,
      WalkBridge bridge,
    })
  >
  build({
    required List<String> script,
    int walkDepth = 3,
    RelayProbe? relayProbe,
    int serverCount = 3,
    List<VpnServer>? servers,
  }) async {
    final resolvedServers = servers ?? [
      walkServer(id: 'a', latencyMs: 5),
      walkServer(id: 'b', latencyMs: 20),
      walkServer(id: 'c', latencyMs: 90),
    ].take(serverCount).toList();
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
            servers: resolvedServers,
            configs: {
              for (final server in resolvedServers)
                server.id: ovpnConfigFor(server.hostAddress!),
            },
          ),
        ],
      ),
      walkDepth: walkDepth,
      walkStepTimeout: stepTimeout,
      relayProbe: relayProbe,
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
      expect(
        harness.bridge.stopCalls,
        1,
        reason: 'the silent attempt was torn down',
      );
    });

    test('when every server is silent the failure names the walk, and a retry reselects', () async {
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

    test(
      'relays that never answered are named, not blamed on the list',
      () async {
        final harness = await build(
          script: ['silent', 'silent', 'silent'],
          walkDepth: 3,
          // Nothing accepts a connection at all. This is the shape the walk
          // has to describe honestly: the probe already proved these relays
          // are not there, so telling the user to retry would be a lie.
          relayProbe: (host, port, timeout) async => false,
        );

        await harness.resolver.resolveAndConnect(
          const SelectionRequest(mode: SelectionMode.recommended),
          connection: harness.controller,
        );

        final view = harness.controller.currentView;
        expect(harness.bridge.startedTo, hasLength(3));
        expect(view.errorCode, 'tunnel.no_relay_reached');
        expect(view.errorMessage, contains('never answered'));
        expect(
          view.errorMessage,
          isNot(contains('try again shortly')),
          reason: 'no retry reaches a relay that never answered',
        );
      },
    );

    test(
      'relays that answered and then failed keep the retry advice',
      () async {
        final harness = await build(
          script: ['silent', 'silent', 'silent'],
          walkDepth: 3,
          // Every relay answers TCP, so each failure is an ordinary one and
          // the list having moved on is a real possibility.
          relayProbe: (host, port, timeout) async => true,
        );

        await harness.resolver.resolveAndConnect(
          const SelectionRequest(mode: SelectionMode.recommended),
          connection: harness.controller,
        );

        final view = harness.controller.currentView;
        expect(view.errorCode, 'tunnel.no_relay_reached');
        expect(view.errorMessage, contains('try again'));
        expect(view.errorMessage, isNot(contains('never answered')));
      },
    );

    test('a config rejection ends the walk instead of being buried', () async {
      final harness = await build(script: ['configRejected']);

      await harness.resolver.resolveAndConnect(
        const SelectionRequest(mode: SelectionMode.recommended),
        connection: harness.controller,
      );
      await pumpEventQueue();

      // The diagnosis applies to the attempt, not only to this server's
      // reachability: a profile the build will not run recurs identically on
      // every server, so walking would just repeat it. The walk stops here and
      // keeps the diagnosis visible.
      expect(harness.bridge.startedTo, hasLength(1));
      final view = harness.controller.currentView;
      expect(view.state.isConnected, isFalse);
      expect(view.errorCode, 'ovpn.config_rejected');
    });

    test('an auth refusal walks to the next ranked relay', () async {
      // A relay-side authentication refusal is that relay's own decision —
      // the app carries no credentials, so nothing about the attempt would
      // change on a retry — and a live walk on the real feed has shown one
      // US relay refusing while its neighbour completed the handshake. The
      // walk must keep the refusal visible as progress, not as terminus.
      final harness = await build(script: ['authFailed', 'silent', 'handshake']);

      await harness.resolver.resolveAndConnect(
        const SelectionRequest(mode: SelectionMode.recommended),
        connection: harness.controller,
      );
      await waitForConnected(harness.controller);

      expect(harness.bridge.startedTo, hasLength(3));
      expect(harness.controller.currentView.state.isConnected, isTrue);
    });

    test(
      'a relay whose handshake was never confirmed is tried once more',
      () async {
        // The live failure from the engine archive: a relay completed the
        // TLS handshake and pushed routes, the exit-address read failed
        // underneath it, and the walk walked past — then reported that no
        // relay had been reached. When there is no relay behind it, the
        // relay that negotiated is the best chance the walk has. SoftEther
        // relays are documented to connect on a later attempt more often
        // than on the first one.
        final harness = await build(
          script: ['leakFail', 'handshake'],
          serverCount: 1,
        );

        await harness.resolver.resolveAndConnect(
          const SelectionRequest(mode: SelectionMode.recommended),
          connection: harness.controller,
        );
        await waitForConnected(harness.controller);

        expect(harness.bridge.startedTo, hasLength(2));
        expect(
          harness.bridge.startedTo.first,
          equals(harness.bridge.startedTo.last),
          reason: 'the retry is the same relay: it is the one that negotiated',
        );
        expect(harness.controller.currentView.state.isConnected, isTrue);
      },
    );

    test(
      'the walk returns to the relay that negotiated even after farther steps',
      () async {
        final harness = await build(
          script: ['leakFail', 'silent', 'silent', 'handshake'],
          walkDepth: 3,
        );

        await harness.resolver.resolveAndConnect(
          const SelectionRequest(mode: SelectionMode.recommended),
          connection: harness.controller,
        );
        await waitForConnected(harness.controller);

        expect(harness.bridge.startedTo, hasLength(4));
        expect(harness.controller.currentView.state.isConnected, isTrue);
      },
    );

    test(
      'a handshake that could not be confirmed twice gets an honest summary',
      () async {
        final harness = await build(
          script: ['leakFail', 'leakFail', 'leakFail', 'leakFail'],
          walkDepth: 3,
        );

        await harness.resolver.resolveAndConnect(
          const SelectionRequest(mode: SelectionMode.recommended),
          connection: harness.controller,
        );
        await waitForError(harness.controller);

        final view = harness.controller.currentView;
        expect(view.state.isConnected, isFalse);
        expect(view.errorCode, 'tunnel.no_relay_reached');
        expect(view.errorMessage, contains('confirmed'));
        expect(view.errorMessage, contains('try again'));
        expect(view.canRetry, isTrue);
      },
    );

    test(
      'the dial begins the moment the best relay answers its probe',
      () async {
        // The sweep must not hold the first dial hostage to the whole pool.
        // A probe that answers nothing used to cost the connect its entire
        // answer budget (measured live: two and a half seconds of sweeping
        // in front of every connect); the dial has to start as early as the
        // listing's own opinion can be confirmed by a single answer.
        final harness = await build(
          script: ['handshake'],
          relayProbe: (host, port, timeout) =>
              host == '192.0.2.${_octetFor('a')}'
              ? Future<bool>.value(true)
              : Completer<bool>().future,
        );

        await harness.resolver.resolveAndConnect(
          const SelectionRequest(mode: SelectionMode.recommended),
          connection: harness.controller,
        );
        // Generous for CI (the budget cap alone is 2.5s), but far more than
        // a dial that waited for it.
        await waitForConnected(
          harness.controller,
          timeout: const Duration(milliseconds: 1500),
        );
        expect(harness.bridge.startedTo, hasLength(1));
      },
    );

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

  group('a country the directory has doubts about is still walked', () {
    test('its relays are dialled, and a silent one is walked past', () async {
      // The live shape behind "Greece is not working": the only Greek relay
      // could not be pinged by the feed, so the directory listed it offline —
      // while the relay itself completed a handshake on the first direct
      // dial. A named country's own relays are what the walk tries; status is
      // a prediction, and the dial is the measurement.
      final harness = await build(
        script: ['silent', 'handshake'],
        servers: [
          walkServer(
            id: 'gr-a',
            latencyMs: 5,
            country: 'GR',
            status: ServerStatus.offline,
          ),
          walkServer(
            id: 'gr-b',
            latencyMs: 40,
            country: 'GR',
            status: ServerStatus.offline,
          ),
        ],
      );

      await harness.resolver.resolveAndConnect(
        const SelectionRequest(
          mode: SelectionMode.recommended,
          countryCode: 'GR',
        ),
        connection: harness.controller,
      );
      await waitForConnected(harness.controller);

      expect(harness.bridge.startedTo, hasLength(2));
      expect(harness.controller.currentView.state.isConnected, isTrue);
    });
  });

  group('a cancelled attempt ends the walk', () {
    test('the next ranked relay is not dialled after the user stops', () async {
      // The dangerous reading of a cancellation is the one a walk already
      // knows: an attempt that produced no outcome because the relay was
      // silent. Read that way, cancelling would send the walk on to the
      // next server — the app connecting to servers after the press.
      final harness = await build(script: ['silent', 'handshake', 'handshake']);

      unawaited(
        harness.resolver.resolveAndConnect(
          const SelectionRequest(mode: SelectionMode.recommended),
          connection: harness.controller,
        ),
      );
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (harness.bridge.startedTo.isEmpty &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(
        harness.bridge.startedTo,
        hasLength(1),
        reason:
            'the walk must be on a server before stopping it means anything',
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
