import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:phantrix_core/phantrix_core.dart';
import 'package:phantrix_platform/phantrix_platform.dart';

import 'package:phantrix/net/app_http_fetcher.dart';
import 'package:phantrix/settings/settings_controller.dart';
import 'package:phantrix/vpn/connection_controller.dart';
import 'package:phantrix/vpn/leak_check.dart';

/// A bridge whose events and methods the test drives directly.
///
/// Extends rather than implements the real bridge so the controller's actual
/// dependency type is satisfied and no member is silently left at its real
/// implementation, which would open a channel and fail in a test.
class FakeBridge extends PhantrixPlatform {
  final events2 = StreamController<PlatformEvent>.broadcast();

  int startCalls = 0;
  int stopCalls = 0;
  AppError? startError;
  AppError? stopError;

  /// What `requestPermission` answers. A held [permissionGate] makes the
  /// call pending, which is how a test observes the consent state while the
  /// (real) operating system dialog would still be on screen.
  bool permission = true;
  Completer<bool>? permissionGate;

  @override
  Stream<PlatformEvent> get events => events2.stream;

  @override
  Future<PlatformCapabilities> capabilities() async => PlatformCapabilities.web;

  @override
  Future<bool> requestPermission() async {
    final gate = permissionGate;
    if (gate != null) {
      return gate.future;
    }
    return permission;
  }

  @override
  Future<Result<void>> startTunnel(TunnelRequest request) async {
    startCalls++;
    final error = startError;
    return error == null ? const Ok(null) : Err(error);
  }

  @override
  Future<Result<void>> stopTunnel() async {
    stopCalls++;
    final error = stopError;
    return error == null ? const Ok(null) : Err(error);
  }

  void emit(PlatformEvent event) => events2.add(event);

  @override
  void dispose() {
    events2.close();
  }
}

/// A bridge whose launch the test holds open.
///
/// The whole point of cancelling is what happens *while* the platform is
/// still working: an attempt that is only cancellable before it starts would
/// be no help at the moment a user actually reaches for the control. A gated
/// launch is how a test keeps that window open for as long as it likes.
class GatedBridge extends FakeBridge {
  /// When set, `startTunnel` does not answer until the test completes it.
  Completer<Result<void>>? launchGate;

  @override
  Future<Result<void>> startTunnel(TunnelRequest request) async {
    startCalls++;
    final gate = launchGate;
    if (gate != null) {
      return gate.future;
    }
    final error = startError;
    return error == null ? const Ok(null) : Err(error);
  }
}

/// Waits until [condition] holds, or fails the test.
///
/// `pumpEventQueue` drains microtasks but does not wait for the mocked HTTP
/// round trip that verification performs, so without this the assertions race
/// the code under test and report a false failure. The controller's own view
/// is included in the failure because "it never became connected" is useless
/// on its own — the reason is already in the error message.
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
        '  error:    ${view.errorCode ?? "-"} / ${view.errorMessage ?? "-"}\n'
        '  handshake:${view.lastHandshakeAt ?? "-"}',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// The rule this file exists to protect: **the app must never report
/// `connected` without real evidence**.
///
/// The evidence is a completed handshake reported by the engine, plus a
/// public address that changed. Nothing here asserts that a tunnel
/// *works* — that needs a device and a server. What these tests assert is
/// that the app cannot *claim* it works without proof.
void main() {
  LeakCheck exitAddress(String body) => LeakCheck(
    fetcher: AppHttpFetcher(
      client: MockClient((_) async => http.Response(body, 200)),
    ),
    // No pause between verification re-reads: these tests judge the
    // state machine, not the retry timing, and the production pause
    // would add seconds to every negative case.
    wait: (_) async {},
  );

  LeakCheck unreachableExitService() => LeakCheck(
    fetcher: AppHttpFetcher(
      client: MockClient((_) async => http.Response('', 503)),
    ),
    wait: (_) async {},
  );

  SettingsController freshSettings() => SettingsController(
    SettingsController().data.copyWith(privacyNoticeAccepted: true),
  );

  Future<ConnectionController> build({
    required LeakCheck leakCheck,
    String? baseline,
  }) async {
    final bridge = FakeBridge();
    addTearDown(bridge.dispose);
    final controller = ConnectionController(
      platform: bridge,
      settings: freshSettings(),
      leakCheck: leakCheck,
    );
    addTearDown(controller.dispose);
    await pumpEventQueue();
    if (baseline != null) {
      controller.debugSetBaselineForTest(baseline);
    }
    return controller;
  }

  PlatformEvent evt(
    PlatformTunnelState state, {
    int? handshakeAtMillis,
    int rx = 0,
    int tx = 0,
  }) => PlatformEvent(
    state: state,
    traffic: PlatformTraffic(rxBytes: rx, txBytes: tx),
    lastHandshakeAtMillis: handshakeAtMillis,
  );

  Future<void> drive(ConnectionController controller) async {
    controller.debugReceive(evt(PlatformTunnelState.preparing));
    controller.debugReceive(evt(PlatformTunnelState.connecting));
    controller.debugReceive(evt(PlatformTunnelState.established));
    await pumpEventQueue();
  }

  group('connected is never reported without a handshake', () {
    test('an interface that is merely up never reaches connected', () async {
      final controller = await build(
        leakCheck: exitAddress('{"ip":"203.0.113.9"}'),
        baseline: '198.51.100.4',
      );
      await drive(controller);

      // `established` means the interface is up. Nothing has crossed it,
      // so the app must still be connecting.
      expect(controller.currentView.state.isConnected, isFalse);
    });

    test('a handshake plus a changed address reaches connected', () async {
      final controller = await build(
        leakCheck: exitAddress('{"ip":"203.0.113.9"}'),
        baseline: '198.51.100.4',
      );
      await drive(controller);

      controller.debugReceive(
        evt(
          PlatformTunnelState.handshaked,
          handshakeAtMillis: DateTime.now().millisecondsSinceEpoch,
          rx: 4096,
          tx: 1024,
        ),
      );
      await pumpEventQueue();

      await waitForConnected(controller);
      // Real engine counters reach the view, not zeros.
      expect(controller.currentView.traffic.rxBytes, 4096);
      expect(controller.currentView.traffic.txBytes, 1024);
      expect(controller.currentView.lastHandshakeAt, isNotNull);
    });

    test('a handshaked state with no handshake time is not a pass', () async {
      // The state name alone must not be trusted. If the engine says
      // "handshaked" but reports no handshake time, the two disagree and
      // the safer reading wins.
      final controller = await build(
        leakCheck: exitAddress('{"ip":"203.0.113.9"}'),
        baseline: '198.51.100.4',
      );
      await drive(controller);

      controller.debugReceive(
        evt(PlatformTunnelState.handshaked, handshakeAtMillis: null),
      );
      await pumpEventQueue();

      expect(controller.currentView.state.isConnected, isFalse);
    });

    test(
      'a dated handshake followed by its undated duplicate still connects',
      () async {
        // The engine reports one handshake as two events: statistics
        // carrying the timestamp, then the state without it. The duplicate
        // must not erase the timestamp the first one carried — that order
        // is the wire contract, and receiving them in it is the exact
        // sequence a live run produced while failing.
        final controller = await build(
          leakCheck: exitAddress('{"ip":"203.0.113.9"}'),
          baseline: '198.51.100.4',
        );
        await drive(controller);

        controller.debugReceive(
          evt(
            PlatformTunnelState.handshaked,
            handshakeAtMillis: DateTime.now().millisecondsSinceEpoch,
            rx: 120,
            tx: 60,
          ),
        );
        controller.debugReceive(evt(PlatformTunnelState.handshaked));
        await pumpEventQueue();
        await waitForConnected(controller);

        expect(controller.currentView.state.isConnected, isTrue);
      },
    );

    test(
      'an undated handshake during a reconnect does not erase a dated one',
      () async {
        // Connected, then the network hiccups: the engine reports
        // reconnecting and then a handshake state without a timestamp (its
        // dated statistics travel separately). The known handshake must
        // survive the duplicate, or a live tunnel is torn down by its own
        // echo.
        final controller = await build(
          leakCheck: exitAddress('{"ip":"203.0.113.9"}'),
          baseline: '198.51.100.4',
        );
        await drive(controller);
        controller.debugReceive(
          evt(
            PlatformTunnelState.handshaked,
            handshakeAtMillis: DateTime.now().millisecondsSinceEpoch,
          ),
        );
        await pumpEventQueue();
        await waitForConnected(controller);

        controller.debugReceive(evt(PlatformTunnelState.reconnecting));
        await pumpEventQueue();
        expect(controller.currentView.state, VpnState.reconnecting);

        controller.debugReceive(evt(PlatformTunnelState.handshaked));
        await pumpEventQueue();
        // Re-verification runs against the preserved timestamp and
        // passes; the tunnel is never torn down.
        await waitForConnected(controller);
        expect(controller.currentView.state.isConnected, isTrue);
      },
    );

    test('a stale handshake is not a pass', () async {
      // The interface is up but the peer stopped answering half an hour
      // ago. Reporting "connected" here is the most misleading thing a
      // VPN can do.
      final controller = await build(
        leakCheck: exitAddress('{"ip":"203.0.113.9"}'),
        baseline: '198.51.100.4',
      );
      await drive(controller);

      controller.debugReceive(
        evt(
          PlatformTunnelState.handshaked,
          handshakeAtMillis: DateTime.now()
              .subtract(const Duration(minutes: 30))
              .millisecondsSinceEpoch,
        ),
      );
      await pumpEventQueue();

      expect(controller.currentView.state.isConnected, isFalse);
    });

    test('an unchanged exit address is a detected leak, not a pass', () async {
      final controller = await build(
        leakCheck: exitAddress('{"ip":"198.51.100.4"}'),
        baseline: '198.51.100.4',
      );
      await drive(controller);

      controller.debugReceive(
        evt(
          PlatformTunnelState.handshaked,
          handshakeAtMillis: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      await pumpEventQueue();

      expect(controller.currentView.state.isConnected, isFalse);
      expect(controller.currentView.errorMessage, contains('did not change'));
    });

    test('an unreachable address service is not a pass', () async {
      // "Could not measure" must never become "no leak".
      final controller = await build(
        leakCheck: unreachableExitService(),
        baseline: '198.51.100.4',
      );
      await drive(controller);

      controller.debugReceive(
        evt(
          PlatformTunnelState.handshaked,
          handshakeAtMillis: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      await pumpEventQueue();

      expect(controller.currentView.state.isConnected, isFalse);
    });
  });

  group('the tunnel is torn down when verification fails', () {
    test('an unverifiable tunnel is stopped, not left half-up', () async {
      final bridge = FakeBridge();
      addTearDown(bridge.dispose);
      final controller = ConnectionController(
        platform: bridge,
        settings: freshSettings(),
        leakCheck: unreachableExitService(),
      );
      addTearDown(controller.dispose);
      await pumpEventQueue();

      controller.debugReceive(evt(PlatformTunnelState.preparing));
      controller.debugReceive(evt(PlatformTunnelState.connecting));
      controller.debugReceive(
        evt(
          PlatformTunnelState.handshaked,
          handshakeAtMillis: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      await pumpEventQueue();

      expect(controller.currentView.state.isConnected, isFalse);
      // The engine must have been told to stop. Leaving the interface up
      // while reporting failure is the worst possible outcome: the user
      // believes they are protected while the tunnel carries nothing.
      expect(bridge.stopCalls, greaterThan(0));
    });
  });

  group('going down', () {
    Future<ConnectionController> connected() async {
      final controller = await build(
        leakCheck: exitAddress('{"ip":"203.0.113.9"}'),
        baseline: '198.51.100.4',
      );
      await drive(controller);
      controller.debugReceive(
        evt(
          PlatformTunnelState.handshaked,
          handshakeAtMillis: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      await pumpEventQueue();
      return controller;
    }

    test('a revoked permission never leaves the UI on connected', () async {
      final controller = await connected();
      await waitForConnected(controller);

      controller.debugReceive(evt(PlatformTunnelState.revoked));
      await pumpEventQueue();
      expect(controller.currentView.state.isConnected, isFalse);
    });

    test('a silent tunnel loss is reflected immediately', () async {
      final controller = await connected();
      await waitForConnected(controller);

      // The engine reports the interface down with no error code, which
      // is what happens when the system reclaims the VPN.
      controller.debugReceive(evt(PlatformTunnelState.idle));
      await pumpEventQueue();
      expect(controller.currentView.state.isConnected, isFalse);
    });

    test('an engine failure is surfaced with its code', () async {
      final controller = await connected();

      controller.debugReceive(
        PlatformEvent(
          state: PlatformTunnelState.failed,
          traffic: PlatformTraffic.empty,
          errorCode: 'tunnel.not_up',
          message: 'The engine could not bring the tunnel up.',
        ),
      );
      await pumpEventQueue();

      expect(controller.currentView.state.isConnected, isFalse);
      expect(controller.currentView.errorCode, 'tunnel.not_up');
    });
  });

  group('a late verification result cannot revive a dead connection', () {
    test(
      'a disconnect during verification is not overwritten by its result',
      () async {
        // Verification performs real network I/O and can take seconds. If the
        // user disconnects in that window, the pending result describes a
        // tunnel that no longer exists, and applying it would leave the UI
        // showing session details for a connection that is gone.
        final gate = Completer<void>();
        final fetcher = AppHttpFetcher(
          client: MockClient((_) async {
            // Hold the request open until the test releases it, which is
            // what makes "during verification" deterministic rather than
            // a race against a fast local response.
            await gate.future;
            return http.Response('{"ip":"203.0.113.9"}', 200);
          }),
        );
        final bridge = FakeBridge();
        addTearDown(bridge.dispose);
        final controller = ConnectionController(
          platform: bridge,
          settings: freshSettings(),
          leakCheck: LeakCheck(fetcher: fetcher),
        );
        addTearDown(controller.dispose);
        await pumpEventQueue();
        controller.debugSetBaselineForTest('198.51.100.4');

        controller.debugReceive(evt(PlatformTunnelState.preparing));
        controller.debugReceive(evt(PlatformTunnelState.connecting));
        controller.debugReceive(
          evt(
            PlatformTunnelState.handshaked,
            handshakeAtMillis: DateTime.now().millisecondsSinceEpoch,
          ),
        );
        // Verification is now blocked inside the HTTP call.
        await Future<void>.delayed(const Duration(milliseconds: 30));

        // The tunnel goes away while the check is in flight.
        controller.debugReceive(evt(PlatformTunnelState.idle));
        await pumpEventQueue();
        expect(controller.currentView.state.isConnected, isFalse);

        // Let the verification finish. Its result says the exit address
        // changed, which would be a pass.
        gate.complete();
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await pumpEventQueue();

        expect(
          controller.currentView.state.isConnected,
          isFalse,
          reason: 'a stale verification result promoted a dead connection',
        );
        expect(
          controller.currentView.session.startedAt,
          isNull,
          reason: 'session details were written for a connection that ended',
        );
      },
    );
  });

  /// The two promises the controller makes about *attempting* a connection:
  /// it never waits forever, and every failure it reports comes with the
  /// action that would actually fix it.
  group('attempts are bounded and failures are actionable', () {
    VpnServer target() => VpnServer(
      id: 's1',
      hostname: 'relay.example',
      hostAddress: '192.0.2.1',
      port: 1194,
      protocol: ProtocolKind.openVpn,
      trustLevel: TrustLevel.projectVerified,
      countryCode: 'DE',
      providerId: 'test',
    );

    VpnConfiguration configuration() {
      const text = '''
client
dev tun
proto tcp
remote relay.example 1194
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
      return VpnConfiguration.openVpn(verdict);
    }

    Future<(ConnectionController, FakeBridge)> connectable({
      Duration connectTimeout = ConnectionController.defaultConnectTimeout,
    }) async {
      final bridge = FakeBridge();
      addTearDown(bridge.dispose);
      final controller = ConnectionController(
        platform: bridge,
        settings: freshSettings(),
        leakCheck: exitAddress('{"ip":"203.0.113.9"}'),
        connectTimeout: connectTimeout,
      );
      addTearDown(controller.dispose);
      await pumpEventQueue();
      controller.debugSetBaselineForTest('198.51.100.4');
      return (controller, bridge);
    }

    Future<void> attempt(ConnectionController controller) => controller.connect(
      server: target(),
      config: configuration(),
      countryLabel: 'Germany',
    );

    test('an attempt the engine never answers fails at the deadline', () async {
      final (controller, bridge) = await connectable(
        connectTimeout: const Duration(milliseconds: 150),
      );

      await attempt(controller);
      // The platform accepted the request and then said nothing at all.
      // That used to be a `preparing` that never ended.
      expect(bridge.startCalls, 1);
      expect(controller.currentView.state, VpnState.preparing);

      await Future<void>.delayed(const Duration(milliseconds: 400));

      final view = controller.currentView;
      expect(view.state, VpnState.error);
      expect(view.errorCode, 'tunnel.timeout');
      expect(view.errorMessage, contains('never reported a handshake'));
      expect(view.canRetry, isTrue);

      // The tunnel is stopped as well as reported: an error card over a
      // half-started tunnel would be the worst of both.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(bridge.stopCalls, greaterThan(0));
    });

    test('consent is its own state, and nothing is built before it', () async {
      final (controller, bridge) = await connectable();
      final gate = Completer<bool>();
      bridge.permissionGate = gate;

      final pending = attempt(controller);
      await pumpEventQueue();

      expect(controller.currentView.state, VpnState.permissionRequired);
      expect(bridge.startCalls, 0, reason: 'the tunnel must not race consent');

      gate.complete(true);
      await pending;

      expect(bridge.startCalls, 1);
      expect(controller.currentView.state, VpnState.preparing);
    });

    test(
      'a refused consent blocks the attempt instead of starting a tunnel',
      () async {
        final (controller, bridge) = await connectable();
        bridge.permission = false;

        await attempt(controller);

        expect(controller.currentView.state, VpnState.blocked);
        expect(controller.currentView.errorCode, 'permission.denied');
        expect(controller.currentView.canRetry, isTrue);
        expect(bridge.startCalls, 0);
      },
    );

    test(
      'retrying a refused consent asks again, then starts the same attempt',
      () async {
        final (controller, bridge) = await connectable();
        bridge.permission = false;
        await attempt(controller);

        bridge.permission = true;
        await controller.retry();

        expect(
          bridge.startCalls,
          1,
          reason: 'the recorded attempt was replayed',
        );
        expect(controller.currentView.state, VpnState.preparing);
      },
    );

    test(
      'a tunnel failure is retried by replaying, not by re-selecting',
      () async {
        final (controller, bridge) = await connectable(
          connectTimeout: const Duration(milliseconds: 150),
        );
        var reselected = 0;
        controller.retrySelection = () async => reselected++;

        await attempt(controller);
        await Future<void>.delayed(const Duration(milliseconds: 400));
        expect(controller.currentView.state, VpnState.error);

        await controller.retry();

        expect(
          bridge.startCalls,
          2,
          reason: 'the same server was dialled again',
        );
        expect(
          reselected,
          0,
          reason: 'the selection was fine; the tunnel was not',
        );
      },
    );

    test(
      'a selection failure is retried by re-selecting, never by replaying',
      () async {
        final (controller, bridge) = await connectable();
        var reselected = 0;
        controller.retrySelection = () async => reselected++;

        controller.reportSelectionFailure('The directory is empty.');
        expect(controller.currentView.state, VpnState.noServerAvailable);

        await controller.retry();

        expect(reselected, 1);
        expect(bridge.startCalls, 0, reason: 'nothing was ever attempted');
      },
    );

    test(
      'disconnect completes the teardown step rather than waiting',
      () async {
        final (controller, bridge) = await connectable();
        await attempt(controller);
        // The attempt itself probed the public address, which the mocked
        // fetcher answers with the same value the tunnel will show. Pin
        // the pre-connection baseline so verification measures a change
        // rather than the mock's single answer.
        controller.debugSetBaselineForTest('198.51.100.4');
        controller.debugReceive(evt(PlatformTunnelState.preparing));
        controller.debugReceive(evt(PlatformTunnelState.connecting));
        controller.debugReceive(
          evt(
            PlatformTunnelState.handshaked,
            handshakeAtMillis: DateTime.now().millisecondsSinceEpoch,
          ),
        );
        await pumpEventQueue();
        await waitForConnected(controller);

        await controller.disconnect();

        expect(controller.currentView.state, VpnState.disconnected);
        expect(bridge.stopCalls, greaterThan(0));
        expect(controller.currentView.errorMessage, isNull);
      },
    );

    test('a refused stop is not presented as disconnected', () async {
      final (controller, bridge) = await connectable();
      await attempt(controller);
      controller.debugSetBaselineForTest('198.51.100.4');
      controller.debugReceive(evt(PlatformTunnelState.preparing));
      controller.debugReceive(evt(PlatformTunnelState.connecting));
      controller.debugReceive(
        evt(
          PlatformTunnelState.handshaked,
          handshakeAtMillis: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      await waitForConnected(controller);
      bridge.stopError = const AppError(
        group: ErrorGroup.tunnel,
        code: 'native.stop_failed',
        message: 'The operating system refused to stop the tunnel.',
      );

      await controller.disconnect();

      expect(controller.currentView.state, VpnState.error);
      expect(controller.currentView.errorCode, 'tunnel.stop_failed');
      expect(controller.currentView.state, isNot(VpnState.disconnected));
      await controller.connect(server: target(), config: configuration());
      expect(
        bridge.startCalls,
        1,
        reason: 'do not overlap a tunnel not stopped',
      );
    });

    test('a new attempt retires the previous attempt error', () async {
      final (controller, bridge) = await connectable(
        connectTimeout: const Duration(milliseconds: 150),
      );

      await attempt(controller);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(controller.currentView.state, VpnState.error);
      expect(controller.currentView.errorCode, 'tunnel.timeout');

      // A second attempt starts clean: the first failure must not sit
      // beside the new session as if it were still true. A live run
      // showed exactly that — a leak refusal displayed under a
      // connected session with traffic.
      await attempt(controller);
      expect(controller.currentView.state, VpnState.preparing);
      expect(controller.currentView.errorCode, isNull);
      expect(controller.currentView.errorMessage, isNull);
      expect(bridge.startCalls, 2);
    });

    test(
      'disconnecting mid-attempt stops the tunnel and cancels the deadline',
      () async {
        final (controller, bridge) = await connectable(
          connectTimeout: const Duration(milliseconds: 150),
        );

        await attempt(controller);
        expect(bridge.startCalls, 1);
        expect(controller.currentView.state, VpnState.preparing);

        await controller.disconnect();

        expect(controller.currentView.state, VpnState.disconnected);
        expect(bridge.stopCalls, greaterThan(0));
        expect(controller.currentView.errorMessage, isNull);

        // The engine confirming the teardown must not become a failure:
        // it is the answer to the stop, not a death.
        controller.debugReceive(evt(PlatformTunnelState.idle));
        await pumpEventQueue();
        expect(controller.currentView.state, VpnState.disconnected);
        expect(controller.currentView.errorCode, isNull);

        // The deadline was armed by the attempt; a teardown must disarm
        // it, or a late timer would rewrite this clean disconnect as a
        // timeout.
        await Future<void>.delayed(const Duration(milliseconds: 400));
        expect(controller.currentView.state, VpnState.disconnected);
        expect(controller.currentView.errorCode, isNull);
      },
    );

    test(
      'an engine that dies mid-attempt is a failure with a retry, not silence',
      () async {
        final (controller, bridge) = await connectable();

        await attempt(controller);
        expect(controller.currentView.state, VpnState.preparing);

        // No user action: the engine simply reports itself gone.
        controller.debugReceive(evt(PlatformTunnelState.idle));
        await pumpEventQueue();

        final view = controller.currentView;
        expect(view.state, VpnState.error);
        expect(view.errorCode, 'tunnel.died');
        expect(view.errorMessage, contains('unexpectedly'));
        expect(view.canRetry, isTrue);
        expect(bridge.stopCalls, greaterThan(0));

        // The failure replays the same server: a dead engine is
        // transient, and re-selecting would blame the directory.
        await controller.retry();
        expect(bridge.startCalls, 2);
      },
    );

    test(
      'connecting while connected stops the old tunnel before starting over',
      () async {
        final (controller, bridge) = await connectable();
        await attempt(controller);
        controller.debugSetBaselineForTest('198.51.100.4');
        controller.debugReceive(evt(PlatformTunnelState.preparing));
        controller.debugReceive(evt(PlatformTunnelState.connecting));
        controller.debugReceive(
          evt(
            PlatformTunnelState.handshaked,
            handshakeAtMillis: DateTime.now().millisecondsSinceEpoch,
          ),
        );
        await pumpEventQueue();
        await waitForConnected(controller);

        // Switching servers: the live tunnel goes down first, and the
        // new attempt starts from disconnected rather than racing it.
        await attempt(controller);

        expect(bridge.stopCalls, greaterThan(0));
        expect(bridge.startCalls, 2);
        expect(controller.currentView.state, VpnState.preparing);
      },
    );

    test(
      'a startTunnel rejection carries its code, and retry replays it',
      () async {
        final (controller, bridge) = await connectable();
        bridge.startError = const AppError(
          group: ErrorGroup.tunnel,
          code: 'ovpn.credentials_missing',
          message:
              'This server needs a username and password, '
              'which this build cannot supply yet.',
        );

        await attempt(controller);

        final view = controller.currentView;
        expect(view.state, VpnState.error);
        expect(view.errorCode, 'ovpn.credentials_missing');
        expect(view.canRetry, isTrue);

        bridge.startError = null;
        await controller.retry();
        expect(bridge.startCalls, 2);
      },
    );

    test(
      'an authentication failure from the engine is surfaced, not swallowed',
      () async {
        final (controller, bridge) = await connectable();

        await attempt(controller);
        controller.debugReceive(
          PlatformEvent(
            state: PlatformTunnelState.failed,
            traffic: PlatformTraffic.empty,
            errorCode: 'ovpn.auth_failed',
            message: 'The server rejected the authentication.',
          ),
        );
        await pumpEventQueue();

        final view = controller.currentView;
        expect(view.state, VpnState.error);
        expect(view.errorCode, 'ovpn.auth_failed');
        expect(view.errorMessage, contains('rejected'));
        expect(view.canRetry, isTrue);
      },
    );

    test('a reconnect that never recovers fails at the deadline', () async {
      final (controller, bridge) = await connectable(
        connectTimeout: const Duration(milliseconds: 150),
      );
      await attempt(controller);
      controller.debugSetBaselineForTest('198.51.100.4');
      controller.debugReceive(evt(PlatformTunnelState.preparing));
      controller.debugReceive(evt(PlatformTunnelState.connecting));
      controller.debugReceive(
        evt(
          PlatformTunnelState.handshaked,
          handshakeAtMillis: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      await pumpEventQueue();
      await waitForConnected(controller);

      controller.debugReceive(evt(PlatformTunnelState.reconnecting));
      await pumpEventQueue();
      expect(controller.currentView.state, VpnState.reconnecting);

      await Future<void>.delayed(const Duration(milliseconds: 400));
      final view = controller.currentView;
      expect(view.state, VpnState.error);
      expect(view.errorCode, 'tunnel.timeout');
      expect(bridge.stopCalls, greaterThan(0));
    });
  });

  /// What the connect control does *after* the user has pressed it.
  ///
  /// Two promises: the press keeps working while an attempt is running —
  /// it cancels instead of going dead — and choosing a different server
  /// abandons whatever is in flight and starts the new one. Both are the
  /// difference between a control the user can act on and one they have to
  /// wait out.
  group('an attempt can be abandoned at any point', () {
    VpnServer target() => VpnServer(
      id: 's1',
      hostname: 'relay.example',
      hostAddress: '192.0.2.1',
      port: 1194,
      protocol: ProtocolKind.openVpn,
      trustLevel: TrustLevel.projectVerified,
      countryCode: 'DE',
      providerId: 'test',
    );

    VpnConfiguration configuration() {
      const text = '''
client
dev tun
proto tcp
remote relay.example 1194
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
      return VpnConfiguration.openVpn(verdict);
    }

    Future<(ConnectionController, FakeBridge)> connectable({
      FakeBridge? withBridge,
    }) async {
      final bridge = withBridge ?? FakeBridge();
      addTearDown(bridge.dispose);
      final controller = ConnectionController(
        platform: bridge,
        settings: freshSettings(),
        leakCheck: exitAddress('{"ip":"203.0.113.9"}'),
      );
      addTearDown(controller.dispose);
      await pumpEventQueue();
      controller.debugSetBaselineForTest('198.51.100.4');
      return (controller, bridge);
    }

    Future<void> attempt(ConnectionController controller) => controller.connect(
      server: target(),
      config: configuration(),
      countryLabel: 'Germany',
    );

    test(
      'cancelling mid-attempt goes back to disconnected, with no failure',
      () async {
        final (controller, bridge) = await connectable();
        await attempt(controller);
        controller.debugReceive(evt(PlatformTunnelState.preparing));
        await pumpEventQueue();
        expect(controller.currentView.state, VpnState.preparing);

        await controller.cancel();

        // A cancelled attempt is not a failed one. Offering a retry for it
        // would tell the user something went wrong when nothing did, and
        // would leave a card on screen for doing exactly what they asked.
        final view = controller.currentView;
        expect(view.state, VpnState.disconnected);
        expect(view.errorMessage, isNull);
        expect(view.errorCode, isNull);
        expect(view.canRetry, isFalse);
        expect(bridge.stopCalls, greaterThan(0));
      },
    );

    test(
      'a launch that answers after the cancel does not resurrect it',
      () async {
        // The platform is still launching — on Windows, the administrator
        // prompt is open — when the user cancels. It answers later, with an
        // error, because the stop tore down what it was starting. That
        // answer belongs to an abandoned attempt and must not become an
        // error card over a view that says "Disconnected".
        final bridge = GatedBridge();
        final (controller, _) = await connectable(withBridge: bridge);
        bridge.launchGate = Completer<Result<void>>();
        unawaited(attempt(controller));
        await pumpEventQueue();
        expect(controller.currentView.state, VpnState.preparing);
        expect(bridge.startCalls, 1);

        await controller.cancel();
        expect(controller.currentView.state, VpnState.disconnected);

        bridge.launchGate!.complete(
          const Err(
            AppError(
              group: ErrorGroup.tunnel,
              code: 'tunnel.failed',
              message: 'The tunnel was stopped while it was starting.',
            ),
          ),
        );
        await pumpEventQueue();

        final view = controller.currentView;
        expect(view.state, VpnState.disconnected);
        expect(view.errorCode, isNull);
        expect(view.errorMessage, isNull);
        // The tunnel the abandoned launch did manage to bring up is still
        // stopped: a view that says "Disconnected" with a live tunnel
        // behind it is the one outcome worse than a stale error card.
        expect(bridge.stopCalls, greaterThan(1));
      },
    );

    test(
      'cancellation resolves the outcome while native launch is pending',
      () async {
        final bridge = GatedBridge()..launchGate = Completer<Result<void>>();
        final (controller, _) = await connectable(withBridge: bridge);
        final pending = controller.connectAndAwait(
          server: target(),
          config: configuration(),
        );
        await pumpEventQueue();
        expect(bridge.startCalls, 1);
        await controller.cancel();
        final outcome = await pending.timeout(const Duration(seconds: 1));
        expect(outcome.code, 'tunnel.cancelled');
        bridge.launchGate!.complete(const Ok(null));
        await pumpEventQueue();
      },
    );

    test(
      'a second attempt replaces the one in flight instead of joining it',
      () async {
        final (controller, bridge) = await connectable();
        await attempt(controller);
        controller.debugReceive(evt(PlatformTunnelState.preparing));
        await pumpEventQueue();
        expect(controller.currentView.state, VpnState.preparing);

        // The user picks another server before the first has answered.
        await controller.connect(
          server: target(),
          config: configuration(),
          countryLabel: 'Austria',
        );

        expect(bridge.startCalls, 2, reason: 'the new server was dialled');
        expect(
          bridge.stopCalls,
          greaterThan(0),
          reason: 'the old attempt was torn down',
        );
        expect(controller.currentView.state, VpnState.preparing);
        expect(controller.currentView.errorMessage, isNull);
        // The replacement's own record, not the abandoned attempt's: what
        // the view names is what a retry would replay.
        expect(controller.currentView.selectedLabel, 'Austria');
      },
    );

    test(
      'a cancellation is an outcome, and one the walk must not follow',
      () async {
        final (controller, _) = await connectable();
        final pending = controller.connectAndAwait(
          server: target(),
          config: configuration(),
          countryLabel: 'Germany',
        );
        await pumpEventQueue();
        expect(controller.currentView.state, VpnState.preparing);

        await controller.cancel();
        final outcome = await pending;

        expect(outcome.connected, isFalse);
        expect(outcome.code, 'tunnel.cancelled');
        // The next relay answers "this one was silent". It is not the
        // answer to "the user stopped asking", and an automatic walk that
        // followed it would keep dialling servers after the press.
        expect(outcome.walkable, isFalse);
        expect(controller.currentView.state, VpnState.disconnected);
      },
    );

    test('a platform error reported after the cancel is dropped', () async {
      // The platform answers its own stop with an error, describing a
      // tunnel that is already gone. Surfacing it would give the user
      // a failure card for the teardown they asked for — and would
      // leave `canRetry` offering to repeat something that never
      // happened.
      final (controller, _) = await connectable();
      await attempt(controller);
      controller.debugReceive(evt(PlatformTunnelState.preparing));
      await pumpEventQueue();

      await controller.cancel();
      expect(controller.currentView.state, VpnState.disconnected);

      controller.debugReceive(
        PlatformEvent(
          state: PlatformTunnelState.failed,
          traffic: PlatformTraffic.empty,
          errorCode: 'tunnel.not_up',
          message: 'The engine could not bring the tunnel up.',
        ),
      );
      await pumpEventQueue();

      final view = controller.currentView;
      expect(view.state, VpnState.disconnected);
      expect(view.errorCode, isNull);
      expect(view.errorMessage, isNull);
      expect(view.canRetry, isFalse);
    });

    test(
      'a teardown nobody here started does not stall the next attempt',
      () async {
        // The system reclaimed the tunnel: `disconnecting` arrives with
        // no local teardown behind it, so there is no future to wait on
        // and no code here that will finish it. Starting over that state
        // is how a change of server would silently do nothing.
        final (controller, bridge) = await connectable();
        await attempt(controller);
        controller.debugSetBaselineForTest('198.51.100.4');
        controller.debugReceive(evt(PlatformTunnelState.preparing));
        controller.debugReceive(evt(PlatformTunnelState.connecting));
        controller.debugReceive(
          evt(
            PlatformTunnelState.handshaked,
            handshakeAtMillis: DateTime.now().millisecondsSinceEpoch,
          ),
        );
        await pumpEventQueue();
        await waitForConnected(controller);

        controller.debugReceive(evt(PlatformTunnelState.disconnecting));
        await pumpEventQueue();
        expect(controller.currentView.state, VpnState.disconnecting);

        unawaited(
          controller.connectAndAwait(
            server: target(),
            config: configuration(),
            countryLabel: 'Germany',
          ),
        );
        await pumpEventQueue();
        // Still coming down, and the new attempt is correctly waiting for
        // it rather than dialling over an engine that is shutting off.
        expect(controller.currentView.state, VpnState.disconnecting);

        controller.debugReceive(evt(PlatformTunnelState.idle));
        await pumpEventQueue();

        expect(controller.currentView.state, VpnState.preparing);
        expect(bridge.startCalls, 2, reason: 'the replacement did connect');
      },
    );

    test('a consent dialog answered after the cancel is dropped', () async {
      final bridge = FakeBridge()..permissionGate = Completer<bool>();
      final (controller, _) = await connectable(withBridge: bridge);
      unawaited(attempt(controller));
      await pumpEventQueue();
      expect(controller.currentView.state, VpnState.permissionRequired);

      await controller.cancel();
      expect(controller.currentView.state, VpnState.disconnected);

      // The user answers the OS dialog anyway. Its "OK" must not start
      // a tunnel the state machine has already been told is gone.
      bridge.permissionGate!.complete(true);
      await pumpEventQueue();

      final view = controller.currentView;
      expect(view.state, VpnState.disconnected);
      expect(bridge.startCalls, 0, reason: 'consent alone must not launch');
    });
  });
}
