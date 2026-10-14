import 'dart:convert';
import 'dart:io';

import 'package:phantrix_core/phantrix_core.dart';

import 'file_vpn_gate_profile_cache.dart';

/// Small, versioned cache of public server metadata.
///
/// This file stores directory metadata only. Public VPN Gate profiles are
/// stored separately by [FileVpnGateProfileCache], allowing an explicit
/// connection attempt during a feed outage without mixing profile material
/// into the visible directory snapshot.
class FileDirectoryCache extends DirectoryCache {
	FileDirectoryCache(this.file);

	factory FileDirectoryCache.inDirectory(String directory) =>
			FileDirectoryCache(File('$directory${Platform.pathSeparator}directory-cache.json'));

	static const int _schemaVersion = 1;
	static const int _maxServers = 2000;
	static const int _maxBytes = 4 * 1024 * 1024;

	final File file;

	@override
	Result<CachedDirectory> read() {
		try {
			if (!file.existsSync()) {
				return const Err(
					AppError(
						group: ErrorGroup.storage,
						code: 'directory_cache.missing',
						message: 'No saved server directory is available.',
					),
				);
			}
			if (file.lengthSync() > _maxBytes) {
				return _corrupt();
			}
			final decoded = jsonDecode(file.readAsStringSync());
			if (decoded is! Map || decoded['version'] != _schemaVersion) {
				return _corrupt();
			}
			final fetchedAtRaw = decoded['fetchedAt'];
			final fetchedAt = fetchedAtRaw is String ? DateTime.tryParse(fetchedAtRaw) : null;
			final rawServers = decoded['servers'];
			if (fetchedAt == null || rawServers is! List || rawServers.isEmpty || rawServers.length > _maxServers) {
				return _corrupt();
			}
			final servers = <VpnServer>[];
			for (final raw in rawServers) {
				if (raw is! Map) {
					return _corrupt();
				}
				servers.add(_decodeServer(raw));
			}
			return Ok(CachedDirectory(List.unmodifiable(servers), fetchedAt.toLocal()));
		} on Object {
			return _corrupt();
		}
	}

	@override
	void write(List<VpnServer> servers, DateTime fetchedAt) {
		if (servers.isEmpty) {
			return;
		}
		try {
			final selected = servers.length > _maxServers
					? servers.sublist(servers.length - _maxServers)
					: servers;
			final payload = jsonEncode({
				'version': _schemaVersion,
				'fetchedAt': fetchedAt.toUtc().toIso8601String(),
				'servers': selected.map(_encodeServer).toList(growable: false),
			});
			if (utf8.encode(payload).length > _maxBytes) {
				return;
			}
			file.parent.createSync(recursive: true);
			final temporary = File('${file.path}.tmp');
			temporary.writeAsStringSync(payload, flush: true);
			temporary.renameSync(file.path);
		} on FileSystemException {
			// Cache writes are opportunistic. The fresh in-memory list remains
			// usable even on a read-only disk or if the device is low on space.
			try {
				final temporary = File('${file.path}.tmp');
				if (temporary.existsSync()) {
					temporary.deleteSync();
				}
			} on FileSystemException {
				// Nothing else can be done safely here.
			}
		}
	}

	@override
	void clear() {
		try {
			if (file.existsSync()) {
				file.deleteSync();
			}
			final temporary = File('${file.path}.tmp');
			if (temporary.existsSync()) {
				temporary.deleteSync();
			}
		} on FileSystemException {
			// Clearing optional metadata must not stop the application.
		}
	}

	static Err<CachedDirectory> _corrupt() => const Err(
		AppError(
			group: ErrorGroup.storage,
			code: 'directory_cache.corrupt',
			message: 'The saved server directory is damaged and will be refreshed.',
		),
	);

	static Map<String, Object?> _encodeServer(VpnServer server) => {
		'id': server.id,
		'hostname': server.hostname,
		'hostAddress': server.hostAddress,
		'port': server.port,
		'protocol': server.protocol.name,
		'trustLevel': server.trustLevel.name,
		'status': server.status.name,
		'countryCode': server.countryCode,
		'providerId': server.providerId,
		'city': server.city,
		'region': server.region,
		'latitude': server.latitude,
		'longitude': server.longitude,
		'loggingPolicy': server.loggingPolicy.name,
		'operatorName': server.operatorName,
		'firstSeenAt': server.firstSeenAt?.toUtc().toIso8601String(),
		'lastSeenAt': server.lastSeenAt?.toUtc().toIso8601String(),
		'requiresCredentials': server.requiresCredentials,
		'fingerprint': server.fingerprint,
		'notes': server.notes,
		'metrics': {
			'latencyMs': server.metrics.latencyMs,
			'handshakeMs': server.metrics.handshakeMs,
			'uptimeRatio': server.metrics.uptimeRatio,
			'successCount': server.metrics.successCount,
			'failureCount': server.metrics.failureCount,
			'consecutiveFailures': server.metrics.consecutiveFailures,
			'activeUsers': server.metrics.activeUsers,
			'downloadMbps': server.metrics.downloadMbps,
			'uploadMbps': server.metrics.uploadMbps,
			'lastMeasuredAt': server.metrics.lastMeasuredAt?.toUtc().toIso8601String(),
			'score': server.metrics.score,
		},
	};

	static VpnServer _decodeServer(Map<dynamic, dynamic> raw) {
		final id = raw['id'];
		final hostname = raw['hostname'];
		final countryCode = raw['countryCode'];
		final providerId = raw['providerId'];
		final canonicalCountry = countryCode is String
				? (GeoDatabase.byIso2(countryCode)?.iso2 ?? GeoDatabase.byIso3(countryCode)?.iso2)
				: null;
		if (id is! String || id.isEmpty ||
			hostname is! String || hostname.isEmpty ||
			canonicalCountry == null ||
			providerId is! String || providerId.isEmpty) {
			throw const FormatException('Required server field missing.');
		}

		final metricsRaw = raw['metrics'];
		final metrics = metricsRaw is Map ? metricsRaw : const <String, Object?>{};
		return VpnServer(
			id: id,
			hostname: hostname,
			hostAddress: _stringOrNull(raw['hostAddress']),
			port: _intOrNull(raw['port']),
			protocol: _enumValue(ProtocolKind.values, raw['protocol'], ProtocolKind.openVpn),
			trustLevel: _enumValue(TrustLevel.values, raw['trustLevel'], TrustLevel.unknown),
			status: _enumValue(ServerStatus.values, raw['status'], ServerStatus.unknown),
			countryCode: canonicalCountry,
			providerId: providerId,
			city: _stringOrNull(raw['city']),
			region: _stringOrNull(raw['region']),
			latitude: _doubleOrNull(raw['latitude']),
			longitude: _doubleOrNull(raw['longitude']),
			loggingPolicy: _enumValue(LoggingPolicy.values, raw['loggingPolicy'], LoggingPolicy.unknown),
			operatorName: _stringOrNull(raw['operatorName']),
			firstSeenAt: _dateOrNull(raw['firstSeenAt']),
			lastSeenAt: _dateOrNull(raw['lastSeenAt']),
			requiresCredentials: raw['requiresCredentials'] == true,
			fingerprint: _stringOrNull(raw['fingerprint']),
			notes: raw['notes'] is List ? (raw['notes'] as List).whereType<String>().take(50).toList() : const [],
			metrics: ServerMetrics(
				latencyMs: _intOrNull(metrics['latencyMs']),
				handshakeMs: _intOrNull(metrics['handshakeMs']),
				uptimeRatio: _doubleOrNull(metrics['uptimeRatio']),
				successCount: _intOrZero(metrics['successCount']),
				failureCount: _intOrZero(metrics['failureCount']),
				consecutiveFailures: _intOrZero(metrics['consecutiveFailures']),
				activeUsers: _intOrNull(metrics['activeUsers']),
				downloadMbps: _doubleOrNull(metrics['downloadMbps']),
				uploadMbps: _doubleOrNull(metrics['uploadMbps']),
				lastMeasuredAt: _dateOrNull(metrics['lastMeasuredAt']),
				score: _intOrNull(metrics['score']),
			),
		);
	}

	static T _enumValue<T extends Enum>(List<T> values, Object? value, T fallback) {
		for (final candidate in values) {
			if (candidate.name == value) {
				return candidate;
			}
		}
		return fallback;
	}

	static String? _stringOrNull(Object? value) => value is String && value.isNotEmpty ? value : null;

	static int? _intOrNull(Object? value) => value is num && value == value.roundToDouble() ? value.toInt() : null;

	static int _intOrZero(Object? value) => _intOrNull(value) ?? 0;

	static double? _doubleOrNull(Object? value) => value is num ? value.toDouble() : null;

	static DateTime? _dateOrNull(Object? value) => value is String ? DateTime.tryParse(value)?.toLocal() : null;
}
