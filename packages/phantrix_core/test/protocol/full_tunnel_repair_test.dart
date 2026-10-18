import 'package:phantrix_core/phantrix_core.dart';
import 'package:test/test.dart';

/// The full-tunnel repair.
///
/// Before this existed, the validator *reported* that a configuration had no
/// default route and recorded the intent to add one, but nothing ever added
/// it. A split-tunnel configuration would therefore have brought the tunnel
/// up and routed only its listed prefixes through it, while every other
/// packet left the device over the physical interface: a silent leak that
/// correct cryptography does not prevent.
///
/// These tests pin the fix: a configuration handed to the engine must always
/// carry the routes that make it a full tunnel.
void main() {
  const wgQuick = '''
[Interface]
PrivateKey = 02R31BtVMJe/5r8cMd8uRVf6DysDrWKFXxDlMdRDU6c=
Address = 10.8.0.2/32

[Peer]
PublicKey = iGaPncC709q7zIxUD9OMJENN3dh+W40oQx0Lv7AStp8=
AllowedIPs = 10.0.0.0/8
Endpoint = 192.0.2.1:51820
''';

  const alreadyFull = '''
[Interface]
PrivateKey = 02R31BtVMJe/5r8cMd8uRVf6DysDrWKFXxDlMdRDU6c=
Address = 10.8.0.2/32

[Peer]
PublicKey = iGaPncC709q7zIxUD9OMJENN3dh+W40oQx0Lv7AStp8=
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = 192.0.2.1:51820
''';

  VpnConfiguration validate(String text) {
    final parsed = WgParser.parse(text).valueOrNull!;
    return VpnConfiguration.wireGuard(
      WgValidator.validate(parsed).valueOrNull!,
    );
  }

  group('split-tunnel repair', () {
    test(
      'a configuration with no default route is not a full tunnel as written',
      () {
        final config = validate(wgQuick);
        expect(config.wireGuard!.isFullTunnel, isFalse);
        expect(
          config.repairs,
          isNotEmpty,
          reason: 'the user was told about it',
        );
      },
    );

    test('the effective configuration does carry the default route', () {
      final effective = validate(wgQuick).effective;
      expect(effective.wireGuard!.isFullTunnel, isTrue);
    });

    test('0.0.0.0/0 is added to the peer', () {
      final allowed = validate(
        wgQuick,
      ).effective.wireGuard!.peers.single.allowedIps;
      expect(
        allowed.any((ip) => ip.isV4 && ip.prefixLength == 0),
        isTrue,
        reason: 'without 0.0.0.0/0 all IPv4 traffic bypasses the tunnel',
      );
    });

    test('::/0 is added so IPv6 cannot bypass either', () {
      final allowed = validate(
        wgQuick,
      ).effective.wireGuard!.peers.single.allowedIps;
      expect(
        allowed.any((ip) => ip.isV6 && ip.prefixLength == 0),
        isTrue,
        reason: 'without ::/0 IPv6 leaks even when IPv4 is tunnelled',
      );
    });

    test('the original split-tunnel prefix is preserved, not replaced', () {
      final allowed = validate(
        wgQuick,
      ).effective.wireGuard!.peers.single.allowedIps;
      expect(
        allowed.any((ip) => ip.address == '10.0.0.0' && ip.prefixLength == 8),
        isTrue,
      );
    });

    test('the original configuration is left untouched for diagnostics', () {
      final original = validate(wgQuick);
      original.effective;
      expect(original.wireGuard!.isFullTunnel, isFalse);
      expect(original.wireGuard!.peers.single.allowedIps, hasLength(1));
    });

    test('applying the repair twice does not duplicate routes', () {
      final once = validate(wgQuick).effective;
      final twice = once.effective;
      expect(
        twice.wireGuard!.peers.single.allowedIps.length,
        once.wireGuard!.peers.single.allowedIps.length,
      );
    });

    test('an already-full configuration is returned unchanged', () {
      final config = validate(alreadyFull);
      expect(config.wireGuard!.isFullTunnel, isTrue);
      expect(identical(config.effective, config), isTrue);
    });

    test('an IPv4-only default is upgraded to cover IPv6 as well', () {
      final config = validate(alreadyFull);
      final wg = config.wireGuard!;
      // Simulate a config that has 0.0.0.0/0 but not ::/0 by narrowing the
      // peer directly, which is the shape a real IPv4-only server sends.
      final ipv4Only = WgConfig(
        interface: wg.interface,
        peers: [
          WgPeer(
            publicKey: wg.peers.single.publicKey,
            endpoint: wg.peers.single.endpoint,
            allowedIps: [const AddressCidr('0.0.0.0', 0)],
          ),
        ],
      );
      final repaired = ipv4Only.withFullTunnelDefaults();
      expect(repaired.peers.single.coversBothFamilies, isTrue);
    });

    test(
      'a configuration with no peers is left alone rather than crashing',
      () {
        const empty = WgConfig(
          interface: WgInterface(privateKey: 'x', addresses: []),
          peers: [],
        );
        expect(empty.withFullTunnelDefaults().peers, isEmpty);
      },
    );

    test('every peer gets a default route, not just the first', () {
      const twoPeers = WgConfig(
        interface: WgInterface(
          privateKey: 'k',
          addresses: [AddressCidr('10.8.0.2', 32)],
        ),
        peers: [
          WgPeer(publicKey: 'a', allowedIps: [AddressCidr('10.0.0.0', 8)]),
          WgPeer(publicKey: 'b', allowedIps: [AddressCidr('10.1.0.0', 16)]),
        ],
      );
      final repaired = twoPeers.withFullTunnelDefaults();
      for (final peer in repaired.peers) {
        expect(
          peer.carriesDefaultRoute,
          isTrue,
          reason: 'peer ${peer.publicKey}',
        );
      }
    });

    test('one peer with a default route is not a full tunnel', () {
      // `isFullTunnel` must mean every peer, not any peer: otherwise a
      // configuration whose second peer routes only a prefix is treated as
      // complete and never repaired.
      const mixed = WgConfig(
        interface: WgInterface(
          privateKey: 'k',
          addresses: [AddressCidr('10.8.0.2', 32)],
        ),
        peers: [
          WgPeer(publicKey: 'a', allowedIps: [AddressCidr('0.0.0.0', 0)]),
          WgPeer(publicKey: 'b', allowedIps: [AddressCidr('10.1.0.0', 16)]),
        ],
      );
      expect(mixed.isFullTunnel, isFalse);

      final effective = VpnConfiguration.wireGuard(
        const WgVerdict(config: mixed, issues: [], routeRepair: false),
      ).effective;
      for (final peer in effective.wireGuard!.peers) {
        expect(
          peer.carriesDefaultRoute,
          isTrue,
          reason: 'peer ${peer.publicKey} was left as a split tunnel',
        );
      }
    });

    test('an OpenVPN configuration is not modified by a WireGuard repair', () {
      // The repair is WireGuard-specific. An OpenVPN config must pass
      // through untouched rather than being given a WireGuard route.
      const ovpn = '''
client
dev tun
proto udp
remote 192.0.2.1 1194
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
      final parsed = OvpnParser.parse(ovpn).valueOrNull!;
      final config = VpnConfiguration.openVpn(
        OvpnValidator.validate(parsed).valueOrNull!,
      );
      expect(identical(config.effective, config), isTrue);
    });
  });
}
