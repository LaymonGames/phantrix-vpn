import '../model/vpn_server.dart';

/// Live data about the current tunnel.
///
/// Every field is either a real measurement or null. The UI must render
/// "unknown" rather than guessing.
class ConnectionSession {
	const ConnectionSession({
		this.server,
		this.startedAt,
		this.assignedIpv4,
		this.assignedIpv6,
		this.lastHandshakeAt,
		this.rxBytes = 0,
		this.txBytes = 0,
		this.rxRate,
		this.txRate,
		this.protocolLabel,
	});

	final VpnServer? server;
	final DateTime? startedAt;

	/// The address the tunnel assigned to this device, when the platform
	/// reports it.
	final String? assignedIpv4;
	final String? assignedIpv6;

	final DateTime? lastHandshakeAt;
	final int rxBytes;
	final int txBytes;
	final int? rxRate;
	final int? txRate;
	final String? protocolLabel;

	static const ConnectionSession none = ConnectionSession();

	bool get isActive => server != null;

	Duration? get duration {
		final at = startedAt;
		if (at == null) {
			return null;
		}
		return DateTime.now().difference(at);
	}

	int get totalBytes => rxBytes + txBytes;

	/// Seconds since the last handshake, or null when never handshaken.
	int? get secondsSinceHandshake {
		final at = lastHandshakeAt;
		if (at == null) {
			return null;
		}
		return DateTime.now().difference(at).inSeconds;
	}

	ConnectionSession copyWith({
		VpnServer? server,
		DateTime? startedAt,
		String? assignedIpv4,
		String? assignedIpv6,
		DateTime? lastHandshakeAt,
		int? rxBytes,
		int? txBytes,
		int? rxRate,
		int? txRate,
		String? protocolLabel,
	}) =>
			ConnectionSession(
				server: server ?? this.server,
				startedAt: startedAt ?? this.startedAt,
				assignedIpv4: assignedIpv4 ?? this.assignedIpv4,
				assignedIpv6: assignedIpv6 ?? this.assignedIpv6,
				lastHandshakeAt: lastHandshakeAt ?? this.lastHandshakeAt,
				rxBytes: rxBytes ?? this.rxBytes,
				txBytes: txBytes ?? this.txBytes,
				rxRate: rxRate ?? this.rxRate,
				txRate: txRate ?? this.txRate,
				protocolLabel: protocolLabel ?? this.protocolLabel,
			);
}
