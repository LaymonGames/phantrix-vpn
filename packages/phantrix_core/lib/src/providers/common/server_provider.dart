import '../../core/app_error.dart';
import '../../model/vpn_server.dart';
import '../../protocol/vpn_configuration.dart';
import 'http_fetcher.dart';
import 'provider_capabilities.dart';


/// A configuration a provider can hand out, plus where it came from.
///
/// [rawText] is the configuration exactly as the provider gave it. It is kept
/// for diagnostics but is never used to start a tunnel; only [validated] is,
/// and it has already passed parsing and security policy.
class ProviderConfig {
	const ProviderConfig({
		required this.providerId,
		required this.rawText,
		required this.validated,
		this.requiresCredentials = false,
	});

	final String providerId;
	final String rawText;
	final VpnConfiguration validated;
	final bool requiresCredentials;
}

/// The outcome of one refresh pass.
///
/// [usedCache] tells the caller whether the data is fresh or last-known, so
/// the UI can say "showing a cached list" instead of lying about freshness.
class RefreshOutcome {
	const RefreshOutcome({
		required this.servers,
		required this.usedCache,
		this.error,
		this.fetchedAt,
	});

	final List<VpnServer> servers;
	final bool usedCache;
	final AppError? error;
	final DateTime? fetchedAt;

	static RefreshOutcome failure(AppError error) =>
			RefreshOutcome(servers: const [], usedCache: false, error: error);

	bool get isOk => error == null;
}

/// One pluggable server source.
///
/// Implementations must:
///  * return server metadata backed by the source, and clearly mark sources
///    that cannot supply tunnel configurations;
///  * return only fully parsed and security-validated configurations from
///    [fetchConfig], even when profile validation is deferred until selection;
///  * never fabricate a status, latency or score;
///  * return [RefreshOutcome.failure] rather than throwing where possible;
///  * be safe to call concurrently.
abstract class ServerProvider {
	/// Stable identifier, e.g. `vpngate`.
	String get id;

	/// Human-readable name shown in Settings.
	String get label;

	ProviderCapabilities get capabilities;

	/// True when this provider should be polled without the user asking.
	bool get autoRefresh => true;

	/// A short description of the trust relationship, shown in the location
	/// browser next to every server from this provider.
	String get trustDescription;

	/// Fetches the current server list.
	///
	/// [force] bypasses short-lived provider memory caches when the user asks
	/// for an explicit refresh. Providers that have no remote cache may ignore it.
	Future<RefreshOutcome> refresh({bool force = false});

	/// Fetches the configuration for [serverId].
	///
	/// Returns null when this provider cannot serve a configuration for the
	/// server, which is a normal outcome for a metadata-only provider.
	Future<ProviderConfig?> fetchConfig(String serverId);

	/// The transport this provider should use; injected so tests can fake it.
	HttpFetcher get fetcher;
}
