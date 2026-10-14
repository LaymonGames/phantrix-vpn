import '../../protocol/protocol_kind.dart';

/// What a provider can actually do.
///
/// Not every provider can hand out a configuration (a metadata-only provider
/// cannot), and app-level code must never assume that it can.
class ProviderCapabilities {
	const ProviderCapabilities({
		this.servesConfigurations = false,
		this.servesMetadataOnly = false,
		this.supportsRefresh = true,
		this.supportsAutoDiscovery = false,
		this.requiresUserAction = false,
		this.protocols = const {},
	});

	final bool servesConfigurations;
	final bool servesMetadataOnly;
	final bool supportsRefresh;
	final bool supportsAutoDiscovery;

	/// True when the user must supply something before the provider can work
	/// (for example pasting a configuration).
	final bool requiresUserAction;
	final Set<ProtocolKind> protocols;

	static const ProviderCapabilities none = ProviderCapabilities();

	static const ProviderCapabilities full = ProviderCapabilities(
		servesConfigurations: true,
		supportsRefresh: true,
		supportsAutoDiscovery: true,
		protocols: {ProtocolKind.wireGuard, ProtocolKind.openVpn},
	);

	static const ProviderCapabilities metadataOnly = ProviderCapabilities(
		servesMetadataOnly: true,
		supportsRefresh: true,
		supportsAutoDiscovery: true,
		protocols: {ProtocolKind.wireGuard},
	);

	static const ProviderCapabilities manualImport = ProviderCapabilities(
		servesConfigurations: true,
		requiresUserAction: true,
		protocols: {ProtocolKind.wireGuard, ProtocolKind.openVpn},
	);
}
