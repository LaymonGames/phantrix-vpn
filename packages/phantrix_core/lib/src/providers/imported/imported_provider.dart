import '../../core/app_error.dart';
import '../../core/result.dart';
import '../../model/server_status.dart';
import '../../model/trust_level.dart';
import '../../model/vpn_server.dart';
import '../../protocol/openvpn/ovpn_parser.dart';
import '../../protocol/openvpn/ovpn_validator.dart';
import '../../protocol/protocol_kind.dart';
import '../../protocol/validation_issue.dart';
import '../../protocol/vpn_configuration.dart';
import '../../protocol/wireguard/wg_parser.dart';
import '../../protocol/wireguard/wg_validator.dart';
import '../common/http_fetcher.dart';
import '../common/provider_capabilities.dart';
import '../common/server_provider.dart';

/// Holds configurations the user pasted or opened.
///
/// Nothing here is uploaded, cached remotely, or reported anywhere. The
/// configuration text itself lives in the app's private storage, and private
/// keys inside it are only ever handed to the platform tunnel through the
/// platform's own secure-storage API.
class ImportedProvider implements ServerProvider {
	ImportedProvider({required this.fetcher, this.onChanged});

	/// Called whenever the set of imports changes, so the app can persist them.
	final void Function(List<ImportedConfig> imports)? onChanged;


@override
	String get id => 'imported';

	@override
	String get label => 'Imported configurations';

	@override
	final HttpFetcher fetcher;

	final List<ImportedConfig> _imports = [];

	List<ImportedConfig> get imports => List.unmodifiable(_imports);

	@override
	ProviderCapabilities get capabilities => const ProviderCapabilities(
		servesConfigurations: true,
		requiresUserAction: true,
		protocols: {ProtocolKind.wireGuard, ProtocolKind.openVpn},
	);

	@override
	bool get autoRefresh => false;

	@override
	String get trustDescription =>
		'You supplied this configuration. Nothing about it has been verified by the '
		'project, so the endpoint operator is whoever runs it.';

	/// Validates and stores a configuration.
	///
	/// The returned result always names the specific problem, because "the
	/// import failed" is never useful enough to act on.
	Future<Result<ImportedConfig>> import(String text, {String? name}) async {
		final trimmed = text.trim();
		if (trimmed.isEmpty) {
			return _fail('import.empty', 'Nothing was pasted or selected.');
		}
		final kind = detectProtocol(trimmed);
		if (kind == null) {
			return _fail(
				'import.unknown_protocol',
				'This does not look like a WireGuard or OpenVPN configuration.',
			);
		}

		final Result<ImportedConfig> result;
		switch (kind) {
			case ProtocolKind.wireGuard:
				result = _importWireGuard(trimmed, name);
			case ProtocolKind.openVpn:
				result = _importOpenVpn(trimmed, name);
		}
		return result;
	}

	Result<ImportedConfig> _importWireGuard(String text, String? name) {
		final parsed = WgParser.parse(text);
		final parsedValue = parsed.valueOrNull;
		if (parsedValue == null) {
			return Err(parsed.errorOrNull!);
		}
		final validated = WgValidator.validate(parsedValue);
		final validatedValue = validated.valueOrNull;
		if (validatedValue == null) {
			return Err(validated.errorOrNull!);
		}
		final expanded = WgValidator.applyFullTunnel(validatedValue.config);
		final revalidated = WgValidator.validate(expanded).valueOrNull;
		if (revalidated == null) {
			return const Err(
				AppError(
					group: ErrorGroup.validation,
					code: 'import.after_repair',
					message: 'The configuration could not be made into a safe full tunnel.',
				),
			);
		}
		final config = VpnConfiguration.wireGuard(revalidated);
		final endpoint = expanded.primaryEndpoint?.host ?? 'unknown';
		final entry = ImportedConfig(
			id: 'wg-${config.fingerprint.hashCode.toRadixString(16)}-$_nextId',
			label: name?.trim().isNotEmpty == true ? name!.trim() : endpoint,
			protocol: ProtocolKind.wireGuard,
			rawText: text,
			configuration: config,
			endpointLabel: endpoint,
			warnings: revalidated.issues,
			repairs: revalidated.routeRepair ? config.repairs : const [],
			createdAt: DateTime.now(),
		);
		_imports.add(entry);
		onChanged?.call(imports);
		return Ok(entry);
	}

	Result<ImportedConfig> _importOpenVpn(String text, String? name) {
		final parsed = OvpnParser.parse(text);
		final parsedValue = parsed.valueOrNull;
		if (parsedValue == null) {
			return Err(parsed.errorOrNull!);
		}
		final validated = OvpnValidator.validate(parsedValue);
		final validatedValue = validated.valueOrNull;
		if (validatedValue == null) {
			return Err(validated.errorOrNull!);
		}
		final config = VpnConfiguration.openVpn(validatedValue);
		final remote = parsedValue.remotes.firstOrNull;
		final entry = ImportedConfig(
			id: 'ovpn-${config.fingerprint.hashCode.toRadixString(16)}-$_nextId',
			label: name?.trim().isNotEmpty == true
					? name!.trim()
					: (remote?.host ?? 'OpenVPN server'),
			protocol: ProtocolKind.openVpn,
			rawText: text,
			configuration: config,
			endpointLabel: remote?.host ?? 'unknown',
			warnings: validatedValue.issues,
			repairs: config.repairs,
			createdAt: DateTime.now(),
		);
		_imports.add(entry);
		onChanged?.call(imports);
		return Ok(entry);
	}

	static int _counter = 0;
	int get _nextId => _counter++;

	/// Detects the protocol from a configuration body.
	static ProtocolKind? detectProtocol(String text) {
		final trimmed = text.trimLeft();
		if (trimmed.startsWith('[Interface]') ||
				RegExp(r'^\s*\[Interface\]', multiLine: true).hasMatch(text)) {
			return ProtocolKind.wireGuard;
		}
		if (RegExp(r'^\s*\[Peer\]', multiLine: true).hasMatch(text)) {
			return ProtocolKind.wireGuard;
		}
		if (RegExp(r'^\s*(client|dev|proto|remote)\s', multiLine: true)
				.hasMatch(text)) {
			return ProtocolKind.openVpn;
		}
		return null;
	}

	Result<ImportedConfig> _fail(String code, String message) => Err(
		AppError(group: ErrorGroup.validation, code: code, message: message),
	);

	@override
	Future<RefreshOutcome> refresh({bool force = false}) async => RefreshOutcome(
		servers: _imports.map((e) => e.toServer()).toList(growable: false),
		usedCache: true,
		fetchedAt: DateTime.now(),
	);

	@override
	Future<ProviderConfig?> fetchConfig(String serverId) async {
		for (final entry in _imports) {
			if (entry.id == serverId) {
				return ProviderConfig(
					providerId: id,
					rawText: entry.rawText,
					validated: entry.configuration,
					requiresCredentials:
							entry.configuration.openVpn?.authUserPass ?? false,
				);
			}
		}
		return null;
	}

	void remove(String id) {
		_imports.removeWhere((e) => e.id == id);
		onChanged?.call(imports);
	}

	void rename(String id, String label) {
		for (var i = 0; i < _imports.length; i++) {
			if (_imports[i].id == id) {
				_imports[i] = _imports[i].copyWith(label: label);
			}
		}
		onChanged?.call(imports);
	}

	void replaceAll(List<ImportedConfig> entries) {
		_imports
			..clear()
			..addAll(entries);
		onChanged?.call(imports);
	}
}

/// A stored, user-supplied configuration.
class ImportedConfig {
	const ImportedConfig({
		required this.id,
		required this.label,
		required this.protocol,
		required this.rawText,
		required this.configuration,
		required this.endpointLabel,
		required this.createdAt,
		this.warnings = const [],
		this.repairs = const [],
	});

	final String id;
	final String label;
	final ProtocolKind protocol;
	final String rawText;
	final VpnConfiguration configuration;
	final String endpointLabel;
	final DateTime createdAt;
	final List<ValidationIssue> warnings;
	final List<String> repairs;

	ImportedConfig copyWith({String? label}) => ImportedConfig(
		id: id,
		label: label ?? this.label,
		protocol: protocol,
		rawText: rawText,
		configuration: configuration,
		endpointLabel: endpointLabel,
		createdAt: createdAt,
		warnings: warnings,
		repairs: repairs,
	);

	VpnServer toServer() => VpnServer(
		id: id,
		hostname: label,
		hostAddress: endpointLabel,
		port: null,
		protocol: protocol,
		trustLevel: TrustLevel.imported,
		status: ServerStatus.unknown,
		countryCode: 'ZZ',
		providerId: id,
		fingerprint: configuration.fingerprint,
		notes: const ['Imported by you. Not verified by the project.'],
		firstSeenAt: createdAt,
		lastSeenAt: createdAt,
	);
}
