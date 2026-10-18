import '../../core/app_error.dart';
import '../../core/result.dart';
import '../../protocol/validation_issue.dart';
import '../address_cidr.dart';
import 'wg_config.dart';
import 'wg_key.dart';

/// The outcome of validating a WireGuard configuration.
class WgVerdict {
  const WgVerdict({
    required this.config,
    required this.issues,
    required this.routeRepair,
  });

  final WgConfig config;
  final List<ValidationIssue> issues;

  /// True when the configuration did not carry the default route and the
  /// engine had to add one.
  final bool routeRepair;
}

/// Post-parse policy checks that decide whether a WireGuard configuration is
/// *safe to use*, as opposed to merely parseable.
///
/// The distinction matters: `wg-quick` happily starts a tunnel that leaks the
/// default route, or that runs `PostUp` shell commands supplied by whoever
/// handed you the file.
class WgValidator {
  const WgValidator._();

  /// Directives that can trigger command execution. Present anywhere in a
  /// file we are given, the config is rejected.
  static const Set<String> forbiddenScriptDirectives = {
    'PreUp',
    'PostUp',
    'PreDown',
    'PostDown',
  };

  static Result<WgVerdict> validate(WgConfig config) {
    final issues = <ValidationIssue>[];

    final keyResult = WireGuardKey.parse(
      config.interface.privateKey,
      field: 'PrivateKey',
    );
    final keyValue = keyResult.valueOrNull;
    if (keyValue == null) {
      return Err(
        AppError(
          group: ErrorGroup.validation,
          code: 'wg.interface.private_key',
          message: 'The tunnel needs a valid private key.',
        ),
      );
    }

    for (final entry in config.unknownDirectives.entries) {
      final leaf = entry.key.split('.').last;
      if (forbiddenScriptDirectives.any(
        (d) => d.toLowerCase() == leaf.toLowerCase(),
      )) {
        return Err(
          AppError(
            group: ErrorGroup.configuration,
            code: 'wg.forbidden_directive',
            message:
                'The configuration uses "$leaf", which can run commands on this '
                'device. Phantrix does not execute directives from configuration '
                'files, so this configuration was rejected.',
            detail: {'directive': leaf},
          ),
        );
      }
      issues.add(
        ValidationIssue(
          code: 'wg.directive.ignored',
          field: entry.key,
          severity: IssueSeverity.info,
          message: '"${entry.key}" is not used by Phantrix and was ignored.',
        ),
      );
    }

    if (config.interface.addresses.isEmpty) {
      return Err(
        const AppError(
          group: ErrorGroup.validation,
          code: 'wg.interface.address',
          message: 'The tunnel needs at least one interface address.',
        ),
      );
    }
    for (final address in config.interface.addresses) {
      if (address.isV4 && address.prefixLength != 32) {
        issues.add(
          ValidationIssue(
            code: 'wg.interface.address_host',
            field: 'Address',
            severity: IssueSeverity.warning,
            message:
                'The IPv4 address $address is not a /32 host address; it is used '
                'exactly as written.',
          ),
        );
      }
    }

    for (final dns in config.interface.dns) {
      if (!AddressCidr.isIpv4(dns) && !AddressCidr.isIpv6(dns)) {
        issues.add(
          ValidationIssue(
            code: 'wg.interface.dns',
            field: 'DNS',
            severity: IssueSeverity.warning,
            message: '"$dns" is not a valid DNS server; the entry was ignored.',
          ),
        );
      }
    }

    var routeRepair = false;
    if (config.peers.isEmpty) {
      return Err(
        const AppError(
          group: ErrorGroup.validation,
          code: 'wg.peer.missing',
          message: 'The tunnel needs at least one peer.',
        ),
      );
    }
    final mtu = config.interface.mtu;
    for (var i = 0; i < config.peers.length; i++) {
      final peer = config.peers[i];
      final label = 'Peer ${i + 1}';
      if (peer.publicKey.isEmpty) {
        return Err(
          AppError(
            group: ErrorGroup.validation,
            code: 'wg.peer.public_key',
            message: '$label has no public key.',
          ),
        );
      }
      if (peer.endpoint == null) {
        return Err(
          AppError(
            group: ErrorGroup.validation,
            code: 'wg.peer.endpoint',
            message:
                '$label has no endpoint. Phantrix cannot know where to send the '
                'handshake, so this configuration is not usable.',
          ),
        );
      }
      if (peer.allowedIps.isEmpty) {
        return Err(
          AppError(
            group: ErrorGroup.validation,
            code: 'wg.peer.allowed_ips',
            message: '$label has no AllowedIPs.',
          ),
        );
      }
      if (!peer.carriesDefaultRoute) {
        routeRepair = true;
        issues.add(
          ValidationIssue(
            code: 'wg.peer.no_default_route',
            field: '$label.AllowedIPs',
            severity: IssueSeverity.warning,
            message:
                '$label does not carry the default route. Phantrix will add '
                '0.0.0.0/0 so traffic cannot leave outside the tunnel.',
          ),
        );
      }
      if (!config.supportsIpv6Route) {
        issues.add(
          ValidationIssue(
            code: 'wg.peer.no_ipv6_route',
            field: '$label.AllowedIPs',
            severity: IssueSeverity.info,
            message:
                'No peer carries an IPv6 default route, so IPv6 will be blocked '
                'while connected instead of being routed elsewhere.',
          ),
        );
      }
      if (mtu != null && mtu < WgConfig.recommendedMtu) {
        issues.add(
          ValidationIssue(
            code: 'wg.interface.mtu_small',
            field: 'Interface.MTU',
            severity: IssueSeverity.warning,
            message:
                'MTU $mtu is very low; if pages fail to load this is usually why.',
          ),
        );
      }
    }

    return Ok(
      WgVerdict(config: config, issues: issues, routeRepair: routeRepair),
    );
  }

  /// Adds the IPv4 default route (`0.0.0.0/0`) to every peer that lacks one,
  /// returning a new config; the original object is untouched. The IPv6
  /// default is left to [WgConfig.withFullTunnelDefaults], which the engine
  /// applies through `VpnConfiguration.effective`.
  static WgConfig applyFullTunnel(WgConfig config) {
    final expanded = <WgPeer>[];
    for (final peer in config.peers) {
      final hasV4 = peer.allowedIps.any((i) => i.isV4 && i.prefixLength == 0);
      final allowed = <AddressCidr>[...peer.allowedIps];
      if (!hasV4) {
        allowed.insert(0, const AddressCidr('0.0.0.0', 0));
      }
      expanded.add(
        WgPeer(
          publicKey: peer.publicKey,
          presharedKey: peer.presharedKey,
          endpoint: peer.endpoint,
          allowedIps: allowed,
          persistentKeepalive: peer.persistentKeepalive,
        ),
      );
    }
    return config.copyWith(peers: expanded);
  }
}
