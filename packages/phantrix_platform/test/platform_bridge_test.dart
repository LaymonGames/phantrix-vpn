import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:phantrix_platform/phantrix_platform.dart';

/// Tests for the parts of the bridge that are pure Dart.
///
/// ## Why this package has tests at all
///
/// Almost everything in `phantrix_platform` is a thin translation layer over a
/// method channel. The value of testing it is concentrated in the places where
/// a mistake is silent: a capability flag that is inverted makes the app offer
/// a protection the platform cannot provide, and a request that drops a field
/// on the way to the engine is a setting the user believes is in effect.
///
/// The native halves — Kotlin, C++, Swift — are covered by their own suites
/// and by the build workflows. Nothing here mocks a connection and calls it a
/// tunnel test.
void main() {
  // Needed by the channel-mock group below. `flutter_test` tests run with a
  // real binding only once something initialises it; nothing else in this
  // file needs it, which is why it was never required before.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PlatformTunnelState', () {
    test('every state survives a round trip through the wire form', () {
      // A native side sending an unknown string must land on [idle]
      // rather than throwing: an event handler that throws takes the
      // connection controller with it.
      for (final state in PlatformTunnelState.values) {
        expect(PlatformTunnelState.fromWire(state.label), state);
      }
    });

    test('an unrecognised state becomes idle, not an exception', () {
      expect(
        PlatformTunnelState.fromWire('something-new'),
        PlatformTunnelState.idle,
      );
      expect(PlatformTunnelState.fromWire(''), PlatformTunnelState.idle);
    });

    test('handshaked is a distinct state from established', () {
      // The distinction is the whole point: "the interface is up" and
      // "the peer answered" are different facts, and collapsing them
      // would let the UI claim a handshake that never happened.
      expect(
        PlatformTunnelState.handshaked,
        isNot(PlatformTunnelState.established),
      );
      expect(
        PlatformTunnelState.fromWire('handshaked'),
        PlatformTunnelState.handshaked,
      );
    });
  });

  group('TunnelRequest', () {
    TunnelRequest build({
      int? mtu = 1420,
      List<String>? allowedApps,
      List<String>? disallowedApps,
      bool? allowLan,
    }) {
      return TunnelRequest(
        configJson: '{"openvpn":{"proto":"udp"}}',
        killSwitchMode: 'automatic',
        dnsMode: 'vpn',
        customDns: const ['10.0.0.1'],
        ipv6Mode: 'block',
        mtuOverride: mtu,
        serverId: 'ovpn-abc123',
        countryLabel: 'Example',
        allowedApps: allowedApps,
        disallowedApps: disallowedApps,
        allowLan: allowLan,
      );
    }

    test('carries every setting the engine needs', () {
      final map = build().toMap();
      expect(map['configJson'], isNotEmpty);
      expect(map['killSwitch'], 'automatic');
      expect(map['dnsMode'], 'vpn');
      expect(map['customDns'], ['10.0.0.1']);
      expect(map['ipv6'], 'block');
      expect(map['mtu'], 1420);
      expect(map['serverId'], 'ovpn-abc123');
    });

    test('omits the optional keys rather than sending null', () {
      // A native side that reads a key's presence to decide whether to
      // apply it would otherwise see "always present" and treat a null
      // as a value.
      final map = build().toMap();
      expect(map.containsKey('allowedApps'), isFalse);
      expect(map.containsKey('disallowedApps'), isFalse);
      expect(map.containsKey('allowLan'), isFalse);
    });

    test('includes the optional keys when they are set', () {
      final map = build(
        allowedApps: const ['com.example.one'],
        allowLan: false,
      ).toMap();
      expect(map['allowedApps'], ['com.example.one']);
      expect(map['allowLan'], false);
    });

    test('a null MTU is sent as null, not silently defaulted', () {
      // The engine has its own default. Substituting one here would make
      // "no override" indistinguishable from "override to 1420", and the
      // two behave differently on a path with an unusual MTU.
      expect(build(mtu: null).toMap()['mtu'], isNull);
    });

    test('the map is JSON-encodable', () {
      // It crosses a method channel, which serialises. A value that
      // cannot be encoded would fail at the boundary rather than here,
      // where the stack trace still points at the cause.
      expect(() => jsonEncode(build().toMap()), returnsNormally);
    });
  });

  group('PlatformEvent', () {
    test('carries both counters and the handshake time', () {
      final event = PlatformEvent(
        state: PlatformTunnelState.handshaked,
        traffic: const PlatformTraffic(rxBytes: 10, txBytes: 4),
        lastHandshakeAtMillis: 1772366400000,
      );
      expect(event.state, PlatformTunnelState.handshaked);
      expect(event.traffic.rxBytes, 10);
      expect(event.traffic.txBytes, 4);
      expect(event.lastHandshakeAtMillis, 1772366400000);
    });

    test('an absent handshake time is null, not the epoch', () {
      // They mean different things: "the peer has never answered" and
      // "it answered in 1970". Collapsing them would let a stale reading
      // be presented as a fresh one.
      const event = PlatformEvent(
        state: PlatformTunnelState.established,
        traffic: PlatformTraffic.empty,
      );
      expect(event.lastHandshakeAtMillis, isNull);
    });

    test('a network change is reported so the caller can reconnect', () {
      const event = PlatformEvent(
        state: PlatformTunnelState.reconnecting,
        traffic: PlatformTraffic.empty,
        networkChanged: true,
      );
      expect(event.networkChanged, isTrue);
    });
  });

  group('capability reporting', () {
    test('the web reports none of the protections it cannot provide', () {
      // The UI must never offer a control the platform reports as
      // unsupported. A wrong `true` here is how a settings screen ends
      // up promising a kill switch the browser has no way to run.
      expect(PlatformCapabilities.web.supportsKillSwitch, isFalse);
      expect(PlatformCapabilities.web.supportsVpnProvidedDns, isFalse);
      expect(PlatformCapabilities.web.supportsIpv6Blocking, isFalse);
      expect(PlatformCapabilities.web.supportsPerAppSplitTunnelling, isFalse);
      expect(PlatformCapabilities.web.supportsAlwaysOn, isFalse);
    });

    test(
      'an unsupported platform explains itself rather than failing blank',
      () {
        // Every screen reads these. An empty map would produce a screen
        // that says nothing about why a setting is unavailable.
        expect(PlatformCapabilities.web.limitations, isNotEmpty);
        for (final entry in PlatformCapabilities.web.limitations.entries) {
          expect(entry.key.trim(), isNotEmpty);
          expect(entry.value.trim(), isNotEmpty);
        }
      },
    );

    test('the web still reports a name, so a bug report is actionable', () {
      expect(PlatformCapabilities.web.platformName.trim(), isNotEmpty);
    });

    test(
      'system lockdown defaults to off, because unknown is not protected',
      () {
        // A default of `true` here would display protection on every
        // platform that simply never answered the question.
        expect(PlatformCapabilities.web.systemLockdown, isFalse);
      },
    );
  });

  group('system lockdown over the channel', () {
    const channelName = 'dev.phantrix.phantrix/tunnel';

    void mock(Object? Function(MethodCall call) handler) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel(channelName),
            (MethodCall call) async => handler(call),
          );
    }

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel(channelName), null);
    });

    test('a lockdown report of true reaches the capabilities', () async {
      mock(
        (call) => switch (call.method) {
          'capabilities' => <String, Object?>{
            'platform': 'android-34',
            'systemLockdown': true,
          },
          _ => null,
        },
      );
      final caps = await PhantrixPlatform().capabilities();
      expect(caps.systemLockdown, isTrue);
    });

    test('a missing lockdown key parses as off, not as an error', () async {
      // Older native builds predate the key. Treating its absence as a
      // failure would red-flag every user who has not updated the native
      // half; treating it as off displays the honest state.
      mock(
        (call) => switch (call.method) {
          'capabilities' => <String, Object?>{'platform': 'android-34'},
          _ => null,
        },
      );
      final caps = await PhantrixPlatform().capabilities();
      expect(caps.systemLockdown, isFalse);
    });

    test(
      'a Windows-shaped report with prose limitations parses, engine included',
      () async {
        // Regression: the Windows backend sends limitations as one prose
        // string while Android sends a map. Parsing assumed a map and threw,
        // which left capabilities() failing and the app believing no engine
        // exists on a machine that had one bundled.
        mock(
          (call) => switch (call.method) {
            'capabilities' => <String, Object?>{
              'platform': 'windows',
              'killSwitch': false,
              'ipv6Block': false,
              'vpnDns': true,
              'perApp': false,
              'lanBypass': false,
              'alwaysOn': false,
              'tray': false,
              'bootStart': false,
              'openVpn': true,
              'engine': 'openvpn-community',
              'limitations':
                  'OpenVPN tunnels run the official community openvpn.exe.',
            },
            _ => null,
          },
        );
        final caps = await PhantrixPlatform().capabilities();
        expect(caps.platformName, 'windows');
        expect(caps.openVpn, isTrue);
        expect(caps.limitations.values.single, contains('openvpn.exe'));
      },
    );

    test('a Windows report with no OpenVPN engine parses as unable', () async {
      // The Windows backend drives a bundled community openvpn.exe, so "no
      // engine" is a state a machine can genuinely be in. Parsing it as
      // available would put the app straight back to offering servers the
      // PC cannot dial.
      mock(
        (call) => switch (call.method) {
          'capabilities' => <String, Object?>{
            'platform': 'windows',
            'openVpn': false,
            'engine': 'openvpn-community',
          },
          _ => null,
        },
      );
      final caps = await PhantrixPlatform().capabilities();
      expect(caps.openVpn, isFalse);
    });

    test('the live reading is true only when the platform says so', () async {
      mock((call) => true);
      expect(await PhantrixPlatform().systemLockdownActive(), isTrue);
    });
    test('the live reading is false when the platform denies it', () async {
      mock((call) => false);
      expect(await PhantrixPlatform().systemLockdownActive(), isFalse);
    });

    test('the live reading is false when no plugin answers', () async {
      // No mock handler at all: MissingPluginException. "Unknown" must
      // never be presented as "protected", so the answer is false rather
      // than a throw the UI would have to catch.
      expect(await PhantrixPlatform().systemLockdownActive(), isFalse);
    });
  });

  group('start on boot over the channel', () {
    const channelName = 'dev.phantrix.phantrix/tunnel';

    void mock(Object? Function(MethodCall call) handler) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel(channelName),
            (MethodCall call) async => handler(call),
          );
    }

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel(channelName), null);
    });

    test('carries the choice to the platform and reports acceptance', () async {
      final calls = <MethodCall>[];
      mock((call) {
        calls.add(call);
        return true;
      });
      expect(await PhantrixPlatform().setStartOnBoot(true), isTrue);
      expect(calls.single.method, 'setBootStart');
      expect(calls.single.arguments, isTrue);
    });

    test('turning it off is carried as an explicit false', () async {
      final calls = <MethodCall>[];
      mock((call) {
        calls.add(call);
        return true;
      });
      expect(await PhantrixPlatform().setStartOnBoot(false), isTrue);
      expect(calls.single.method, 'setBootStart');
      expect(calls.single.arguments, isFalse);
    });

    test('a refusal reaches the caller as false, not as a throw', () async {
      // The settings screen treats `true` as "the machine agreed". An
      // exception here would take the screen down instead of putting the
      // switch back where it was.
      mock((call) => throw PlatformException(code: 'boot.registry_failed'));
      expect(await PhantrixPlatform().setStartOnBoot(true), isFalse);
    });

    test('a platform without the method reports false', () async {
      // No mock handler at all: MissingPluginException. Reporting the
      // preference as saved would promise a start-up that cannot happen.
      expect(await PhantrixPlatform().setStartOnBoot(true), isFalse);
    });
  });
}
