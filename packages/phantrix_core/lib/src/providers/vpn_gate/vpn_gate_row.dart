import 'dart:convert';

import '../../core/app_error.dart';
import '../../core/result.dart';
import '../../model/logging_policy.dart';
import '../../model/server_status.dart';

/// Raw fields as published by the VPN Gate relay feed.
///
/// See <https://www.vpngate.net/api/iphone/>. The feed is CSV with a leading
/// `#` header line and a `*` trailer; every row also carries a base64
/// OpenVPN configuration.
class VpnGateRow {
	const VpnGateRow({
		required this.hostName,
		required this.ip,
		required this.score,
		required this.ping,
		required this.countryLong,
		required this.countryShort,
		required this.sessions,
		required this.uptimeSeconds,
		required this.totalUsers,
		required this.logType,
		required this.operator,
		required this.message,
		required this.configBase64,
	});

	final String hostName;
	final String ip;
	final int? score;
	final int? ping;
	final String countryLong;
	final String countryShort;
	final int? sessions;
	final int? uptimeSeconds;
	final int? totalUsers;
	final String logType;
	final String operator;
	final String message;
	final String configBase64;

	static const int fieldCount = 15;

	/// The decoded OpenVPN configuration, or null when it is not valid base64.
	String? get config {
		if (configBase64.isEmpty) {
			return null;
		}
		try {
			return utf8.decode(base64Decode(configBase64));
		} on FormatException {
			return null;
		}
	}

	double get uptimeRatio {
		final seconds = uptimeSeconds;
		if (seconds == null || seconds <= 0) {
			return 0;
		}
		// The feed reports cumulative uptime; normalising against a month keeps
		// a very long-lived relay from looking infinitely reliable.
		const month = 30 * 24 * 60 * 60;
		final ratio = seconds / month;
		return ratio.clamp(0, 1).toDouble();
	}

	String get countryCode {
		final raw = countryShort.trim().toUpperCase();
		if (RegExp(r'^[A-Z]{2}$').hasMatch(raw)) {
			return raw;
		}
		// The feed occasionally uses three-letter codes; keep them so the UI can
		// still group the server rather than dropping it.
		return raw.length == 3 ? raw : '';
	}
}

/// Parses the VPN Gate CSV feed.
class VpnGateParser {
	const VpnGateParser._();

	static Result<List<VpnGateRow>> parse(String body) {
		final rows = <VpnGateRow>[];
		for (final line in const LineSplitter().convert(body)) {
			final row = parseLine(line);
			if (row != null) {
				rows.add(row);
			}
		}
		if (rows.isEmpty) {
			return const Err(
				AppError(
					group: ErrorGroup.provider,
					code: 'vpn_gate.empty',
					message: 'The VPN Gate feed was read but contained no servers.',
				),
			);
		}
		return Ok(rows);
	}

	/// Parses one CSV line, returning null for banners, headers and malformed
	/// rows. This is also used by the streaming provider so it can stop reading
	/// after it has enough relays instead of buffering the full catalog.
	static VpnGateRow? parseLine(String line) {
		final trimmed = line.trim();
		if (trimmed.isEmpty || trimmed.startsWith('*') || trimmed.startsWith('#')) {
			return null;
		}
		final parts = trimmed.split(',');
		if (parts.length < VpnGateRow.fieldCount) {
			return null;
		}
		return VpnGateRow(
			hostName: parts[0].trim(),
			ip: parts[1].trim(),
			score: int.tryParse(parts[2].trim()),
			ping: int.tryParse(parts[3].trim()),
			countryLong: parts[5].trim(),
			countryShort: parts[6].trim(),
			sessions: int.tryParse(parts[7].trim()),
			uptimeSeconds: int.tryParse(parts[8].trim()),
			totalUsers: int.tryParse(parts[9].trim()),
			logType: parts[11].trim(),
			operator: parts[12].trim(),
			message: parts[13].trim(),
			// The configuration column can contain separators in malformed feed
			// rows; preserve the remainder for the Base64 validator to reject.
			configBase64: parts.sublist(14).join(',').trim(),
		);
	}

	static ServerStatus statusFor(VpnGateRow row) {
		final ping = row.ping;
		if (ping == null || ping <= 0 || ping > 5000) {
			return ServerStatus.offline;
		}
		return ping < 400 ? ServerStatus.online : ServerStatus.degraded;
	}

	static LoggingPolicy loggingFor(VpnGateRow row) =>
			LoggingPolicy.fromVpnGate(row.logType);
}
