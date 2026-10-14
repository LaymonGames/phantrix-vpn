import 'dart:convert';
import 'dart:developer' as developer;

import '../../core/app_error.dart';
import '../../core/result.dart';
import '../../model/trust_level.dart';
import '../../model/vpn_server.dart';
import '../../protocol/openvpn/ovpn_parser.dart';
import '../../protocol/openvpn/ovpn_validator.dart';
import '../../protocol/protocol_kind.dart';
import '../../protocol/vpn_configuration.dart';
import '../common/http_fetcher.dart';
import '../common/provider_capabilities.dart';
import '../common/server_provider.dart';
import 'vpn_gate_profile_cache.dart';
import 'vpn_gate_row.dart';

/// The public VPN Gate volunteer relay network.
///
/// <https://www.vpngate.net/api/iphone/>
///
/// Every entry is operated by an unknown volunteer. The operator can observe
/// your traffic once it leaves the tunnel, so these servers are always
/// labelled `publicRelay` and are never presented as trustworthy.
///
/// Discovery only parses public metadata. The relatively expensive Base64
/// decode, OpenVPN parse, and security validation are performed when a relay is
/// actually selected. An unvalidated profile is never returned by
/// [fetchConfig], and therefore can never be passed to a tunnel backend.
class VpnGateProvider implements ServerProvider {
	VpnGateProvider({required this.fetcher, VpnGateProfileCache? profileCache})
		: profileCache = profileCache ?? MemoryVpnGateProfileCache() {
		_profileBase64.addAll(this.profileCache.read());
	}

	static const String defaultEndpoint = 'https://www.vpngate.net/api/iphone/';
	static const Duration cacheTtl = Duration(seconds: 45);
	static const Duration missingProfileRefreshCooldown = Duration(seconds: 15);
	static const int maxCachedProfiles = 2000;

	@override
	String get id => 'vpngate';

	@override
	String get label => 'VPN Gate (public volunteer relays)';

	@override
	final HttpFetcher fetcher;

	/// Public feed profiles may be retained in app-private storage so the user
	/// can make a connection attempt during a feed outage. These are untrusted
	/// input and are always re-validated before tunnel startup.
	final VpnGateProfileCache profileCache;
	final Map<String, String> _profileBase64 = {};

	/// Stores successful and failed validation results so a repeated selection
	/// does not parse the same profile again. Null means it was rejected.
	final Map<String, ({String raw, VpnConfiguration config})?> _validatedConfigs = {};

	List<VpnServer> _cachedServers = const [];
	DateTime? _cachedFetchedAt;
	Future<RefreshOutcome>? _refreshFuture;
	DateTime? _lastMissingProfileRecoveryAttemptAt;

	Uri get endpoint => Uri.parse(defaultEndpoint);

	@override
	ProviderCapabilities get capabilities => const ProviderCapabilities(
		servesConfigurations: true,
		supportsRefresh: true,
		supportsAutoDiscovery: true,
		protocols: {ProtocolKind.openVpn},
	);

	@override
	bool get autoRefresh => true;

	@override
	String get trustDescription =>
		'Run by unknown volunteers. The operator can observe the traffic that exits '
		'through their server.';

	@override
	Future<RefreshOutcome> refresh({bool force = false}) async {
		final cachedAt = _cachedFetchedAt;
		if (!force && _cachedServers.isNotEmpty && cachedAt != null) {
			final age = DateTime.now().difference(cachedAt);
			if (!age.isNegative && age < cacheTtl) {
				return RefreshOutcome(
					servers: _cachedServers,
					usedCache: true,
					fetchedAt: cachedAt,
				);
			}
		}

		final active = _refreshFuture;
		if (active != null) {
			return active;
		}

		final future = _refreshInternal();
		_refreshFuture = future;
		try {
			return await future;
		} finally {
			if (identical(_refreshFuture, future)) {
				_refreshFuture = null;
			}
		}
	}

	Future<RefreshOutcome> _refreshInternal() async {
		final totalWatch = Stopwatch()..start();
		final fetchWatch = Stopwatch()..start();
		final rows = <VpnGateRow>[];
		final seenHosts = <String>{};
		AppError? streamError;
		var fetchMs = 0;
		var parseMs = 0;
		var streamMs = 0;
		var feedRows = 0;

		if (fetcher is HttpLineFetcher) {
			// Read the large VPN Gate CSV incrementally. As soon as enough usable
			// relays have been found, break out of the stream; cancellation stops
			// downloading and parsing the remaining records.
			final parseWatch = Stopwatch();
			try {
				await for (final line in (fetcher as HttpLineFetcher).getLines(endpoint)) {
					parseWatch.start();
					final row = VpnGateParser.parseLine(line);
					parseWatch.stop();
					if (row == null) {
						continue;
					}
					feedRows++;
					if (row.hostName.isEmpty ||
							row.ip.isEmpty ||
							row.countryCode.isEmpty ||
							row.configBase64.isEmpty ||
							!seenHosts.add(row.hostName)) {
						continue;
					}
					rows.add(row);
					if (rows.length >= maxCachedProfiles) {
						break;
					}
				}
			} on AppError catch (error) {
				streamError = error;
			} catch (error) {
				streamError = AppError(
					group: ErrorGroup.network,
					code: 'vpn_gate.stream_failed',
					message: 'The VPN Gate feed could not be read completely.',
					detail: {'cause': error.runtimeType.toString()},
				);
			}
			streamMs = fetchWatch.elapsedMilliseconds;
			parseMs = parseWatch.elapsedMilliseconds;
		} else {
			// Keep compatibility with test doubles and third-party HttpFetcher
			// implementations that only expose the all-at-once get() API.
			final String body;
			try {
				body = await fetcher.get(endpoint);
			} on AppError catch (error) {
				developer.log(
					'refresh_failed stage=fetch code=${error.code}',
					name: 'phantrix.discovery',
					level: 900,
				);
				return _failureWithStaleCache(error);
			} on BodyTooLargeException catch (error) {
				final appError = error.asError();
				developer.log(
					'refresh_failed stage=fetch code=${appError.code}',
					name: 'phantrix.discovery',
					level: 900,
				);
				return _failureWithStaleCache(appError);
			}
			fetchMs = fetchWatch.elapsedMilliseconds;

			final parseWatch = Stopwatch()..start();
			final parsed = VpnGateParser.parse(body);
			parseMs = parseWatch.elapsedMilliseconds;
			if (parsed case Err(error: final error)) {
				developer.log(
					'refresh_failed stage=parse code=${error.code}',
					name: 'phantrix.discovery',
					level: 900,
				);
				return _failureWithStaleCache(error);
			}
			feedRows = parsed.valueOr.length;
			for (final row in parsed.valueOr) {
				if (rows.length >= maxCachedProfiles) {
					break;
				}
				if (row.hostName.isEmpty ||
						row.ip.isEmpty ||
						row.countryCode.isEmpty ||
						row.configBase64.isEmpty ||
						!seenHosts.add(row.hostName)) {
					continue;
				}
				rows.add(row);
			}
		}

		if (rows.isEmpty) {
			final error = streamError ?? const AppError(
				group: ErrorGroup.provider,
				code: 'vpn_gate.no_usable_relays',
				message: 'VPN Gate returned no relay entries with OpenVPN profiles.',
			);
			developer.log(
				'refresh_failed stage=parse code=${error.code}',
				name: 'phantrix.discovery',
				level: 900,
			);
			return _failureWithStaleCache(error);
		}

		if (streamError != null) {
			// A truncated feed may still contain many complete, usable CSV rows.
			// Keep those rows instead of discarding all of them because the feed
			// failed after yielding useful data.
			developer.log(
				'partial_feed=true code=${streamError.code} usable_rows=${rows.length}',
				name: 'phantrix.discovery',
				level: 900,
			);
		}

		final now = DateTime.now();
		final buildWatch = Stopwatch()..start();
		final servers = <VpnServer>[];
		final profileBase64ById = <String, String>{};
		for (final row in rows) {
			profileBase64ById[row.hostName] = row.configBase64;
			servers.add(_toServer(row, now));
		}

		if (servers.isEmpty) {
			return _failureWithStaleCache(
				const AppError(
					group: ErrorGroup.provider,
					code: 'vpn_gate.no_usable_relays',
					message: 'VPN Gate returned no relay entries with OpenVPN profiles.',
				),
			);
		}

		// Prefer newly fetched profiles but retain older saved profiles too. This
		// matters when a previously selected relay falls outside the first batch
		// of results or the current feed is truncated after several good rows.
		final retainedProfiles = <String, String>{...profileBase64ById};
		for (final entry in _profileBase64.entries) {
			if (retainedProfiles.length >= maxCachedProfiles) {
				break;
			}
			retainedProfiles.putIfAbsent(entry.key, () => entry.value);
		}
		_profileBase64
			..clear()
			..addAll(retainedProfiles);
		// The cache contains provider-published profiles only, never imported
		// keys. Every restored profile is re-validated before tunnel startup.
		profileCache.write(_profileBase64);
		_validatedConfigs.clear();
		_cachedServers = List.unmodifiable(servers);
		_cachedFetchedAt = now;

		developer.log(
			'fetch_ms=$fetchMs parse_ms=$parseMs stream_ms=$streamMs '
				'metadata_ms=${buildWatch.elapsedMilliseconds} '
				'total_ms=${totalWatch.elapsedMilliseconds} feed_rows=$feedRows '
				'published_relays=${servers.length} '
				'partial_feed_error=${streamError?.code ?? "none"}',
			name: 'phantrix.discovery',
		);

		return RefreshOutcome(servers: _cachedServers, usedCache: false, fetchedAt: now);
	}

	RefreshOutcome _failureWithStaleCache(AppError error) {
		final fetchedAt = _cachedFetchedAt;
		if (_cachedServers.isNotEmpty && fetchedAt != null) {
			return RefreshOutcome(
				servers: _cachedServers,
				usedCache: true,
				error: error,
				fetchedAt: fetchedAt,
			);
		}
		return RefreshOutcome.failure(error);
	}

	/// Parses and security-checks a profile only when it is selected. Returns
	/// null if decoding, parsing, validation, or policy checks reject it.
	({String raw, VpnConfiguration config})? _accept(String? raw) {
		if (raw == null || raw.isEmpty) {
			return null;
		}
		final parsed = OvpnParser.parse(raw);
		final parsedValue = parsed.valueOrNull;
		if (parsedValue == null) {
			return null;
		}
		final validated = OvpnValidator.validate(parsedValue);
		final validatedValue = validated.valueOrNull;
		if (validatedValue == null) {
			return null;
		}
		return (raw: raw, config: VpnConfiguration.openVpn(validatedValue));
	}

	@override
	Future<ProviderConfig?> fetchConfig(String serverId) async {
		if (_validatedConfigs.containsKey(serverId)) {
			final cached = _validatedConfigs[serverId];
			return cached == null ? null : _providerConfig(cached);
		}

		var encoded = _profileBase64[serverId];
		if (encoded == null || encoded.isEmpty) {
			// Older builds saved only the directory metadata, not the profiles.
			// On the first attempt after upgrading, a cached server ID can exist
			// without a cached profile. Refresh once on demand to migrate that
			// state; a server-list refresh is never a prerequisite when a profile
			// is already available. The cooldown prevents automatic fallback from
			// hammering the feed once per candidate after a failed request.
			final activeRefresh = _refreshFuture;
			if (activeRefresh != null) {
				// The app may be bootstrapping the directory in the background. If
				// the selected profile is not cached yet, share that in-flight fetch
				// instead of failing before its result is available. Count it as the
				// recovery attempt so fallback candidates do not repeat the same feed.
				_lastMissingProfileRecoveryAttemptAt = DateTime.now();
				await activeRefresh;
				encoded = _profileBase64[serverId];
			} else {
				final lastAttempt = _lastMissingProfileRecoveryAttemptAt;
				final canRetry = lastAttempt == null ||
						DateTime.now().difference(lastAttempt) >= missingProfileRefreshCooldown;
				if (canRetry) {
					_lastMissingProfileRecoveryAttemptAt = DateTime.now();
					await refresh(force: true);
					encoded = _profileBase64[serverId];
				}
			}
		}
		if (encoded == null || encoded.isEmpty) {
			return null;
		}

		final watch = Stopwatch()..start();
		final accepted = _accept(_decodeConfig(encoded));
		_validatedConfigs[serverId] = accepted;
		developer.log(
			'profile_validation_ms=${watch.elapsedMilliseconds} accepted=${accepted != null}',
			name: 'phantrix.discovery',
		);
		return accepted == null ? null : _providerConfig(accepted);
	}


	String? _decodeConfig(String encoded) {
		try {
			return utf8.decode(base64Decode(encoded));
		} on FormatException {
			return null;
		}
	}

	ProviderConfig _providerConfig(({String raw, VpnConfiguration config}) entry) =>
		ProviderConfig(
			providerId: id,
			rawText: entry.raw,
			validated: entry.config,
			requiresCredentials: entry.config.openVpn?.authUserPass ?? false,
		);

	VpnServer _toServer(VpnGateRow row, DateTime now) {
		return VpnServer(
			id: row.hostName,
			hostname: row.hostName,
			hostAddress: row.ip,
			port: null,
			protocol: ProtocolKind.openVpn,
			trustLevel: TrustLevel.publicRelay,
			status: VpnGateParser.statusFor(row),
			countryCode: row.countryCode,
			providerId: id,
			city: _city(row),
			loggingPolicy: VpnGateParser.loggingFor(row),
			operatorName: row.operator.isEmpty ? null : row.operator,
			metrics: ServerMetrics(
				latencyMs: row.ping,
				uptimeRatio: row.uptimeRatio,
				score: row.score,
				activeUsers: row.sessions,
				lastMeasuredAt: now,
			),
			firstSeenAt: now,
			lastSeenAt: now,
			fingerprint: row.hostName,
			notes: [
				if (row.logType.isNotEmpty) 'Operator states logging policy: ${row.logType}',
			],
		);
	}

	String? _city(VpnGateRow row) {
		final match = RegExp(r'^[^;(]*\(([^)]+)\)').firstMatch(row.operator);
		final city = match?.group(1)?.trim();
		return city == null || city.isEmpty ? null : city;
	}
}
