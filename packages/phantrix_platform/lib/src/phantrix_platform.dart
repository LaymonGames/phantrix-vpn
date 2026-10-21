import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:phantrix_core/phantrix_core.dart';

import 'platform_capabilities.dart';
import 'platform_event.dart';
import 'platform_traffic.dart';
import 'platform_tunnel_state.dart';
import 'tunnel_request.dart';

/// The single entry point from Dart into the native tunnel.
///
/// On the web this is a no-op object whose [capabilities] is
/// [PlatformCapabilities.web], and whose [startTunnel] fails with an explicit
/// message rather than pretending.
class PhantrixPlatform {
  PhantrixPlatform({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('dev.phantrix.phantrix/tunnel');

  final MethodChannel _channel;

  static const EventChannel _events = EventChannel(
    'dev.phantrix.phantrix/tunnelEvents',
  );

  static const String _methodStart = 'startTunnel';
  static const String _methodStop = 'stopTunnel';
  static const String _methodCapabilities = 'capabilities';
  static const String _methodPermission = 'requestPermission';
  static const String _methodOpenSettings = 'openVpnSettings';
  static const String _methodDataDirectory = 'appDataDirectory';
  static const String _methodSystemLockdown = 'systemLockdown';
  static const String _methodSetBootStart = 'setBootStart';

  final _controller = StreamController<PlatformEvent>.broadcast();
  bool _listening = false;
  bool _disposed = false;
  StreamSubscription<Object?>? _nativeEvents;

  Stream<PlatformEvent> get events {
    if (!_listening && !_disposed && !kIsWeb) {
      _listening = true;
      _nativeEvents = _events.receiveBroadcastStream().listen(
        _onEvent,
        onError: (Object error) {
          if (!_disposed) {
            _controller.add(
              const PlatformEvent(
                state: PlatformTunnelState.failed,
                traffic: PlatformTraffic.empty,
                errorCode: 'platform.events_failed',
                message: 'The tunnel event channel stopped responding.',
              ),
            );
          }
        },
      );
    }
    return _controller.stream;
  }

  void _onEvent(Object? event) {
    if (_disposed) {
      return;
    }
    final map = event is Map
        ? event.cast<String, Object?>()
        : const <String, Object?>{};
    final state = PlatformTunnelState.fromWire(
      map['state'] as String? ?? 'idle',
    );
    final trafficMap =
        (map['traffic'] as Map?)?.cast<String, Object?>() ?? const {};
    final traffic = _trafficFrom(trafficMap);
    final capsMap = (map['capabilities'] as Map?)?.cast<String, Object?>();
    _controller.add(
      PlatformEvent(
        state: state,
        traffic: traffic,
        message: map['message'] as String?,
        errorCode: map['errorCode'] as String?,
        networkChanged: map['networkChanged'] == true,
        // Its own top-level field rather than part of `traffic`, because
        // it decides whether "connected" may be claimed at all. Null
        // means no handshake was observed, which differs from one at the epoch.
        lastHandshakeAtMillis: (map['lastHandshakeAtMillis'] as num?)?.toInt(),
        capabilities: capsMap == null ? null : _capabilitiesFrom(capsMap),
      ),
    );
  }

  static PlatformTraffic _trafficFrom(Map<String, Object?> map) =>
      PlatformTraffic(
        rxBytes: (map['rx'] as num?)?.toInt() ?? 0,
        txBytes: (map['tx'] as num?)?.toInt() ?? 0,
        rxRate: (map['rxRate'] as num?)?.toInt(),
        txRate: (map['txRate'] as num?)?.toInt(),
        lastHandshake: _parseTime(map['lastHandshake']),
        assignedIpv4: map['ipv4'] as String?,
        assignedIpv6: map['ipv6'] as String?,
        protocolLabel: map['protocol'] as String?,
      );

  static DateTime? _parseTime(Object? value) {
    if (value is num) {
      return DateTime.fromMillisecondsSinceEpoch(value.toInt());
    }
    if (value is String) {
      final fromMs = int.tryParse(value);
      if (fromMs != null) {
        return DateTime.fromMillisecondsSinceEpoch(fromMs);
      }
      return DateTime.tryParse(value)?.toLocal();
    }
    return null;
  }

  static PlatformCapabilities _capabilitiesFrom(Map<String, Object?> map) =>
      PlatformCapabilities(
        platformName: map['platform'] as String? ?? 'unknown',
        supportsKillSwitch: map['killSwitch'] as bool? ?? false,
        supportsIpv6Blocking: map['ipv6Block'] as bool? ?? false,
        supportsVpnProvidedDns: map['vpnDns'] as bool? ?? false,
        supportsPerAppSplitTunnelling: map['perApp'] as bool? ?? false,
        supportsLanBypass: map['lanBypass'] as bool? ?? false,
        supportsAlwaysOn: map['alwaysOn'] as bool? ?? false,
        supportsTray: map['tray'] as bool? ?? false,
        supportsBootStart: map['bootStart'] as bool? ?? false,
        openVpn: map['openVpn'] as bool? ?? false,
        systemLockdown: map['systemLockdown'] as bool? ?? false,
        limitations: _limitationsFrom(map['limitations']),
      );

  /// Reads the platform's limitation notes, in either shape a backend sends.
  ///
  /// Android sends a map of keyed notes; Windows sends one prose string.
  /// Both must parse: the Windows string shape once crashed capabilities
  /// parsing outright (as Map? on a String), which left the app believing
  /// no engine exists on a machine that had one. A single note becomes one
  /// entry, so the UI renders it like every other limitation.
  static Map<String, String> _limitationsFrom(Object? value) {
    if (value is Map) {
      return value.cast<String, Object?>().map(
        (key, item) => MapEntry(key, item.toString()),
      );
    }
    if (value is String && value.isNotEmpty) {
      return {'note': value};
    }
    if (value is List) {
      return {
        for (var i = 0; i < value.length; i++)
          if (value[i] is String) 'note$i': value[i] as String,
      };
    }
    return const {};
  }

  /// What this host can do.
  Future<PlatformCapabilities> capabilities() async {
    if (kIsWeb) {
      return PlatformCapabilities.web;
    }
    try {
      final result = await _channel.invokeMapMethod<String, Object?>(
        _methodCapabilities,
      );
      if (result == null) {
        return _unknownCapabilities();
      }
      return _capabilitiesFrom(result);
    } on PlatformException catch (error) {
      return _unknownCapabilities(error: error);
    } on MissingPluginException {
      return _unknownCapabilities();
    }
  }

  static PlatformCapabilities _unknownCapabilities({Object? error}) =>
      PlatformCapabilities(
        platformName: 'unknown',
        supportsKillSwitch: false,
        supportsIpv6Blocking: false,
        supportsVpnProvidedDns: false,
        supportsPerAppSplitTunnelling: false,
        supportsLanBypass: false,
        supportsAlwaysOn: false,
        supportsTray: false,
        supportsBootStart: false,
        limitations: {
          if (error != null)
            'platform':
                'The platform layer could not be reached, so nothing is '
                'reported as supported.',
        },
      );

  /// Requests the OS VPN permission (Android VpnService, iOS/macOS Network
  /// Extension authorisation).
  ///
  /// Returns true when the permission is now available, false when the user
  /// declined. Never throws for a refusal.
  Future<bool> requestPermission() async {
    try {
      final result = await _channel.invokeMethod<bool>(_methodPermission);
      return result ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Asks the OS to open its own VPN settings screen.
  Future<void> openSystemVpnSettings() async {
    try {
      await _channel.invokeMethod<void>(_methodOpenSettings);
    } on PlatformException {
      // The user can open it themselves.
    } on MissingPluginException {
      // Unsupported host.
    }
  }

  /// Whether the operating system is currently blocking traffic outside a
  /// VPN itself.
  ///
  /// Read live on every call — the user can flip the switch in the system
  /// settings while the app runs, so a cached answer would report
  /// protection that is no longer there. False on every platform except
  /// Android, and false there until Always-on VPN with "Block connections
  /// without VPN" points at this app. Never throws: "unknown" must never be
  /// presented as "protected".
  Future<bool> systemLockdownActive() async {
    try {
      return await _channel.invokeMethod<bool>(_methodSystemLockdown) ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Registers or removes the app's start-at-sign-in entry.
  ///
  /// On Windows this is one per-user value under the shell's own start-up
  /// key: no administrator and no installer take part. Returns true only
  /// when the platform recorded the choice — false means the switch belongs
  /// back where it was, because a preference the machine refused is not a
  /// preference in effect.
  Future<bool> setStartOnBoot(bool enabled) async {
    try {
      final result = await _channel.invokeMethod<bool>(
        _methodSetBootStart,
        enabled,
      );
      return result ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Starts the tunnel.
  ///
  /// The returned result reports success only when the platform accepted the
  /// request, not when the tunnel is up. Reading [events] is the only way to
  /// know that.
  Future<Result<void>> startTunnel(TunnelRequest request) async {
    try {
      await _channel.invokeMethod<void>(_methodStart, request.toMap());
      return const Ok(null);
    } on PlatformException catch (error) {
      return Err(_fromPlatformException(error));
    } on MissingPluginException {
      return const Err(
        AppError(
          group: ErrorGroup.permission,
          code: 'platform.missing',
          message: 'This platform has no Phantrix tunnel implementation.',
        ),
      );
    }
  }

  /// Stops the tunnel. Always cleans up, even mid-connect.
  Future<Result<void>> stopTunnel() async {
    try {
      await _channel.invokeMethod<void>(_methodStop);
      return const Ok(null);
    } on PlatformException catch (error) {
      return Err(_fromPlatformException(error));
    } on MissingPluginException {
      return const Ok(null);
    }
  }

  /// Where the app may keep private files.
  ///
  /// This is the platform's own private location: `filesDir` on Android,
  /// `%LOCALAPPDATA%\Phantrix` on Windows, `$XDG_CONFIG_HOME/phantrix` on
  /// Linux, the application-support directory on Apple. It is returned as a
  /// path rather than handled by a plugin method because the app does its own
  /// file I/O and the semantics of "write a file" are identical everywhere;
  /// only the directory differs.
  ///
  /// Returns null where the platform has no private writable location, which
  /// today means the web, where nothing may be persisted at all. Callers must
  /// treat null as "this session only" rather than as an error: an app that
  /// cannot persist still has to work.
  Future<String?> appDataDirectory() async {
    try {
      return await _channel.invokeMethod<String>(_methodDataDirectory);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Releases the stream. Call on app dispose.
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    unawaited(_nativeEvents?.cancel());
    unawaited(_controller.close());
  }
}

AppError _fromPlatformException(PlatformException error) => AppError(
  group: _groupFor(error.code),
  code: error.code,
  message: _messageFor(error.code, error.message),
  cause: error,
);

ErrorGroup _groupFor(String code) {
  if (code.startsWith('wg.') || code.startsWith('ovpn.')) {
    return ErrorGroup.tunnel;
  }
  if (code.startsWith('permission.') || code.startsWith('dns.')) {
    return ErrorGroup.permission;
  }
  if (code.startsWith('server.')) {
    return ErrorGroup.provider;
  }
  return ErrorGroup.unknown;
}

String _messageFor(String code, String? raw) {
  final detail = raw?.trim();
  return switch (code) {
    'permission.denied' => 'The operating system did not grant VPN permission.',
    'permission.revoked' =>
      'VPN permission was withdrawn. Phantrix stopped the tunnel.',
    'permission.always_on_conflict' =>
      'Another VPN is currently active on this device.',
    'ovpn.auth_failed' =>
      'This relay refused the session. Volunteer relays sometimes reject '
          'connections when they are overloaded or blocked.',
    'ovpn.tls_failed' => 'The TLS handshake failed.',
    'ovpn.driver_failed' =>
      'The VPN tunnel driver could not be set up on this computer.',
    'ovpn.driver_not_registered' =>
      'The VPN adapter was created but could not be registered with the '
          'OpenVPN engine, so the engine would not have found it.',
    'server.unreachable' => 'The VPN server could not be reached.',
    'server.overloaded' => 'The VPN server is overloaded.',
    'dns.failed' => 'The VPN DNS could not be configured.',
    'network.changed' => 'The network changed while connecting.',
    'kill_switch.unsupported' =>
      'This platform cannot enforce a strict kill switch.',
    _ =>
      detail == null || detail.isEmpty
          ? 'The tunnel could not be started.'
          : detail,
  };
}
