import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import 'package:phantrix_core/phantrix_core.dart';

/// The state a platform reports for its tunnel.
///
/// This mirrors, but is not the same as, `VpnState`. The platform describes
/// what the OS is doing; the state machine decides what that means. In
/// particular `established` is never the same as connected.
enum PlatformTunnelState {
	idle('idle'),
	preparing('preparing'),
	connecting('connecting'),
	established('established'),

	/// The engine holds the interface and has completed the protocol's
	/// handshake with the peer recently — a Noise_IK handshake for
	/// WireGuard, or OpenVPN's "Initialization Sequence Completed" for
	/// OpenVPN — with the time of that event in the event's
	/// `lastHandshakeAtMillis`.
	///
	/// This is a stronger claim than [established] and a weaker one than a
	/// verified leak check. The distinction exists because "the tunnel
	/// interface is up" and "the peer answered" are different facts, and
	/// only the second one proves anything is being carried.
	///
	/// For OpenVPN the native side must refresh `lastHandshakeAtMillis` on
	/// every reconnect, so the freshness check the Dart side applies measures
	/// the current session rather than one from a previous network.
	handshaked('handshaked'),
	reconnecting('reconnecting'),
	disconnecting('disconnecting'),
	failed('failed'),
	revoked('revoked');

	const PlatformTunnelState(this.label);

	final String label;

	static PlatformTunnelState fromWire(String value) => switch (value) {
		'idle' => PlatformTunnelState.idle,
		'preparing' => PlatformTunnelState.preparing,
		'connecting' => PlatformTunnelState.connecting,
		'established' => PlatformTunnelState.established,
		'handshaked' => PlatformTunnelState.handshaked,
		'reconnecting' => PlatformTunnelState.reconnecting,
		'disconnecting' => PlatformTunnelState.disconnecting,
		'failed' => PlatformTunnelState.failed,
		'revoked' => PlatformTunnelState.revoked,
		_ => PlatformTunnelState.idle,
	};
}

/// A traffic sample from the platform's tunnel interface.
class PlatformTraffic {
	const PlatformTraffic({
		required this.rxBytes,
		required this.txBytes,
		this.rxRate,
		this.txRate,
		this.lastHandshake,
		this.assignedIpv4,
		this.assignedIpv6,
		this.protocolLabel,
	});

	final int rxBytes;
	final int txBytes;
	final int? rxRate;
	final int? txRate;
	final DateTime? lastHandshake;
	final String? assignedIpv4;
	final String? assignedIpv6;
	final String? protocolLabel;

	static const PlatformTraffic empty = PlatformTraffic(rxBytes: 0, txBytes: 0);
}

/// What the host can actually do, as reported by the native side.
///
/// The UI must never offer a control the platform reports as unsupported.
class PlatformCapabilities {
	const PlatformCapabilities({
		required this.platformName,
		required this.supportsKillSwitch,
		required this.supportsIpv6Blocking,
		required this.supportsVpnProvidedDns,
		required this.supportsPerAppSplitTunnelling,
		required this.supportsLanBypass,
		required this.supportsAlwaysOn,
		required this.supportsTray,
		required this.supportsBootStart,
		this.openVpn = false,
		this.systemLockdown = false,
		this.limitations = const {},
	});

	final String platformName;
	/// Whether the backend can block traffic itself when the tunnel drops.
	///
	/// This is false on every platform today, and that is a deliberate
	/// statement rather than a missing feature flag: none of the backends
	/// installs a traffic-blocking rule that survives the tunnel interface.
	/// Android's genuine protection is the operating system's own Always-on
	/// VPN lockdown, which is reported separately as [systemLockdown] because
	/// it is a system setting the user controls, not something the app does.
	final bool supportsKillSwitch;
	final bool supportsIpv6Blocking;
	final bool supportsVpnProvidedDns;
	final bool supportsPerAppSplitTunnelling;
	final bool supportsLanBypass;
	final bool supportsAlwaysOn;
	final bool supportsTray;
	final bool supportsBootStart;

	/// Whether this host can actually start an OpenVPN tunnel, as reported
	/// by the native side (the bundled community `openvpn.exe` plus helper on
	/// Windows; always false on Android, which has no OpenVPN engine).
	///
	/// False everywhere until a platform reports it, so an OpenVPN server is
	/// rejected with an explanation instead of being attempted and failing
	/// inside the engine. The Dart side never assumes it: an engine that is
	/// not there must not be advertised as one.
	final bool openVpn;

	/// Whether the operating system is currently blocking traffic outside a
	/// VPN itself (Android's Always-on VPN with "Block connections without
	/// VPN", pointing at this app).
	///
	/// This is the only genuine kill switch on stock Android, and it belongs
	/// to the system settings, not to the app — which is why it is a separate
	/// reading rather than part of [supportsKillSwitch]. False everywhere
	/// except Android, and false on Android until the user enables it.
	final bool systemLockdown;

	/// Human-readable explanations of what this platform cannot do.
	final Map<String, String> limitations;

	static const PlatformCapabilities web = PlatformCapabilities(
		platformName: 'web',
		supportsKillSwitch: false,
		supportsIpv6Blocking: false,
		supportsVpnProvidedDns: false,
		supportsPerAppSplitTunnelling: false,
		supportsLanBypass: false,
		supportsAlwaysOn: false,
		supportsTray: false,
		supportsBootStart: false,
		limitations: {
			'kill_switch':
				'A browser cannot protect traffic outside itself. A system-wide '
				'client on Windows, macOS, Linux, Android or iOS is required.',
		},
	);
}

/// A tunnel request handed to the native side.
///
/// Every field is derived from a [VpnConfiguration] that has already passed
/// parsing and security validation.
class TunnelRequest {
	const TunnelRequest({
		required this.configJson,
		required this.killSwitchMode,
		required this.dnsMode,
		required this.customDns,
		required this.ipv6Mode,
		required this.mtuOverride,
		required this.serverId,
		required this.countryLabel,
		this.allowedApps,
		this.disallowedApps,
		this.allowLan,
		this.ovpnConfig,
	});

	final String configJson;
	final String killSwitchMode;
	final String dnsMode;
	final List<String> customDns;
	final String ipv6Mode;
	final int? mtuOverride;
	final String serverId;
	final String countryLabel;
	final List<String>? allowedApps;
	final List<String>? disallowedApps;
	final bool? allowLan;

	/// The complete `.ovpn` profile text for an OpenVPN connection, null
	/// for WireGuard.
	///
	/// Serialised once, in Dart, by [OvpnSerializer] — full-tunnel routing
	/// already normalised — so the native side never re-implements config
	/// parsing or route policy. Native still re-checks the profile for
	/// execution-capable directives before writing it out; this field is the
	/// single source of what the engine will be told.
	final String? ovpnConfig;

	Map<String, Object?> toMap() => {
		'configJson': configJson,
		'killSwitch': killSwitchMode,
		'dnsMode': dnsMode,
		'customDns': customDns,
		'ipv6': ipv6Mode,
		'mtu': mtuOverride,
		'serverId': serverId,
		'countryLabel': countryLabel,
		if (allowedApps != null) 'allowedApps': allowedApps,
		if (disallowedApps != null) 'disallowedApps': disallowedApps,
		if (allowLan != null) 'allowLan': allowLan,
		if (ovpnConfig != null) 'ovpnConfig': ovpnConfig,
	};
}

/// Live platform facts, pushed from the native side.
class PlatformEvent {
	const PlatformEvent({
		required this.state,
		required this.traffic,
		this.message,
		this.errorCode,
		this.capabilities,
		this.networkChanged = false,
		this.lastHandshakeAtMillis,
	});

	final PlatformTunnelState state;
	final PlatformTraffic traffic;

	/// Unix milliseconds of the last handshake the engine observed.
	///
	/// Null when no handshake has happened yet, which is materially different
	/// from a handshake at the epoch: the first means the peer has never answered,
	/// the second means it did and the reading is stale.
	final int? lastHandshakeAtMillis;

	/// A short, non-secret human message.
	final String? message;

	/// A stable machine code, for example `wg.handshake_timeout`.
	final String? errorCode;

	/// Reported by the platform on start-up and after a capability change.
	final PlatformCapabilities? capabilities;

	/// True when the OS reported that the underlying network changed.
	final bool networkChanged;
}

/// The single entry point from Dart into the native tunnel.
///
/// On the web this is a no-op object whose [capabilities] is
/// [PlatformCapabilities.web], and whose [startTunnel] fails with an explicit
/// message rather than pretending.
class PhantrixPlatform {
	PhantrixPlatform({MethodChannel? channel})
		: _channel = channel ??
				const MethodChannel('dev.phantrix.phantrix/tunnel');

	final MethodChannel _channel;

	static const EventChannel _events =
			EventChannel('dev.phantrix.phantrix/tunnelEvents');

	static const String _methodStart = 'startTunnel';
	static const String _methodStop = 'stopTunnel';
	static const String _methodCapabilities = 'capabilities';
	static const String _methodPermission = 'requestPermission';
	static const String _methodOpenSettings = 'openVpnSettings';
	static const String _methodReport = 'reportVerification';
	static const String _methodDataDirectory = 'appDataDirectory';
	static const String _methodSystemLockdown = 'systemLockdown';

	final _controller = StreamController<PlatformEvent>.broadcast();
	bool _listening = false;
	PlatformCapabilities? _cachedCapabilities;

	Stream<PlatformEvent> get events {
		if (!_listening) {
			_listening = true;
			_events.receiveBroadcastStream().listen(_onEvent);
		}
		return _controller.stream;
	}

	void _onEvent(Object? event) {
		final map =
				event is Map ? event.cast<String, Object?>() : const <String, Object?>{};
		final state = PlatformTunnelState.fromWire(map['state'] as String? ?? 'idle');
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

	static PlatformTraffic _trafficFrom(Map<String, Object?> map) => PlatformTraffic(
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
			return value
				.cast<String, Object?>()
				.map((key, item) => MapEntry(key, item.toString()));
		}
		if (value is String && value.isNotEmpty) {
			return {'note': value};
		}
		return const {};
	}


	/// What this host can do.
	Future<PlatformCapabilities> capabilities() async {
		final cached = _cachedCapabilities;
		if (cached != null) {
			return cached;
		}
		try {
			final result =
					await _channel.invokeMapMethod<String, Object?>(_methodCapabilities);
			if (result == null) {
				return _unknownCapabilities();
			}
			_cachedCapabilities = _capabilitiesFrom(result);
			return _cachedCapabilities!;
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

	/// Tells the platform that the caller verified the tunnel, which is what
	/// allows the state machine to report "connected".
	Future<void> reportVerification({
		required String assignedIpv4,
		required String assignedIpv6,
		required String protocolLabel,
	}) async {
		try {
			await _channel.invokeMethod<void>(_methodReport, {
				'ipv4': assignedIpv4,
				'ipv6': assignedIpv6,
				'protocol': protocolLabel,
			});
		} on PlatformException {
			// The Dart state machine already knows.
		} on MissingPluginException {
			// Ignored.
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
		'permission.denied' =>
			'The operating system did not grant VPN permission.',
		'permission.revoked' =>
			'VPN permission was withdrawn. Phantrix stopped the tunnel.',
		'permission.always_on_conflict' =>
			'Another VPN is currently active on this device.',
		'wg.handshake_timeout' =>
			'The WireGuard handshake did not complete. The server may be '
				'unreachable or the configuration stale.',
		'wg.config_invalid' => 'The WireGuard configuration was rejected.',
		'ovpn.auth_failed' => 'The server rejected the credentials.',
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
		_ => detail == null || detail.isEmpty
				? 'The tunnel could not be started.'
				: detail,
	};
}

/// JSON encoding shared with the native side.
///
/// The payload never leaves the device. The native side is responsible for
/// keeping it out of its own logs.
class TunnelJson {
	const TunnelJson._();

	/// Serialises a validated configuration for the platform tunnel.
	static String encode(VpnConfiguration config) {
		final wireGuard = config.wireGuard;
		final openVpn = config.openVpn;
		final json = <String, Object?>{
			'kind': config.kind.name,
			if (wireGuard != null)
				'wireguard': {
					'privateKey': wireGuard.interface.privateKey,
					'addresses':
							wireGuard.interface.addresses.map((a) => a.toString()).toList(),
					'dns': wireGuard.interface.dns,
					'mtu': wireGuard.interface.mtu,
					'listenPort': wireGuard.interface.listenPort,
					'peers': wireGuard.peers
							.map(
								(p) => {
									'publicKey': p.publicKey,
									if (p.presharedKey != null) 'presharedKey': p.presharedKey,
									'endpoint': p.endpoint?.display,
									'allowedIps': p.allowedIps.map((i) => i.toString()).toList(),
									'persistentKeepalive': p.persistentKeepalive,
								},
							)
							.toList(),
				},
			if (openVpn != null)
				'openvpn': {
					'proto': openVpn.proto,
					'dev': openVpn.dev,
					'cipher': openVpn.cipher,
					'auth': openVpn.auth,
					'remotes': openVpn.remotes
							.map((r) => {'host': r.host, 'port': r.port, 'proto': r.proto})
							.toList(),
					'ca': openVpn.inlineBlocks['ca']?.body,
					'cert': openVpn.inlineBlocks['cert']?.body,
					'key': openVpn.inlineBlocks['key']?.body,
					'tlsAuth': openVpn.inlineBlocks['tls-auth']?.body,
					'authUserPass': openVpn.authUserPass,
				},
		};
		return jsonEncode(json);
	}
}