/// Phantrix core: platform-agnostic domain logic.
///
/// This library deliberately has no Flutter dependency and no platform
/// dependency. It contains:
///  * protocol parsing, validation and serialisation (WireGuard, OpenVPN);
///  * the pluggable server-provider system and the discovery layer;
///  * server scoring and selection;
///  * the connection state machine;
///  * settings, diagnostics and the secret-redacting logger.
///
/// Everything that touches an operating system lives in
/// `package:phantrix_platform`.
library;

export 'src/core/app_error.dart';
export 'src/core/result.dart';
export 'src/core/selection_reason.dart';
export 'src/diagnostics/diagnostics.dart';
export 'src/discovery/directory_cache.dart';
export 'src/discovery/memory_directory_cache.dart';
export 'src/discovery/server_directory.dart';
export 'src/discovery/server_merger.dart';
export 'src/geo/geo_database.dart';
export 'src/logging/fingerprint.dart';
export 'src/logging/logger.dart';
export 'src/logging/redactor.dart';
export 'src/model/logging_policy.dart';
export 'src/model/server_status.dart';
export 'src/model/trust_level.dart';
export 'src/model/vpn_server.dart';
export 'src/protocol/address_cidr.dart';
export 'src/protocol/endpoint.dart';
export 'src/protocol/openvpn/ovpn_parser.dart';
export 'src/protocol/openvpn/ovpn_serializer.dart';
export 'src/protocol/openvpn/ovpn_validator.dart';
export 'src/protocol/protocol_kind.dart';
export 'src/protocol/validation_issue.dart';
export 'src/protocol/vpn_configuration.dart';
export 'src/protocol/wireguard/wg_config.dart';
export 'src/protocol/wireguard/wg_parser.dart';
export 'src/protocol/wireguard/wg_validator.dart';
export 'src/providers/common/http_fetcher.dart';
export 'src/providers/common/provider_capabilities.dart';
export 'src/providers/common/server_provider.dart';
export 'src/providers/imported/imported_provider.dart';
export 'src/providers/manifest/manifest_provider.dart';
export 'src/providers/manifest/manifest_schema.dart';
export 'src/providers/vpn_gate/vpn_gate_profile_cache.dart';
export 'src/providers/vpn_gate/vpn_gate_provider.dart';
export 'src/providers/vpn_gate/vpn_gate_row.dart';
export 'src/scoring/selection_mode.dart';
export 'src/scoring/server_scorer.dart';
export 'src/scoring/server_selector.dart';
export 'src/settings/app_settings.dart';
export 'src/vpn/connection_session.dart';
export 'src/vpn/vpn_engine.dart';
export 'src/vpn/vpn_state_machine.dart';
