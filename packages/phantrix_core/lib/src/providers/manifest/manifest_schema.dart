import '../../core/app_error.dart';
import '../../core/result.dart';
import '../../model/trust_level.dart';
import '../../protocol/protocol_kind.dart';

/// One entry in a project server manifest.
///
/// The schema is deliberately small and every field is validated before the
/// entry becomes a server. A manifest can describe a server it does not run,
/// but it can never make the app talk to something it should not.
class ManifestEntry {
  const ManifestEntry({
    required this.id,
    required this.hostname,
    required this.countryCode,
    required this.protocol,
    required this.endpoints,
    required this.config,
    required this.trustLevel,
    this.city,
    this.latitude,
    this.longitude,
    this.operatorName,
    this.signedBy,
    this.expiresAt,
    this.notes = const [],
  });

  final String id;
  final String hostname;
  final String countryCode;
  final ProtocolKind protocol;
  final List<String> endpoints;
  final String config;
  final TrustLevel trustLevel;
  final String? city;
  final double? latitude;
  final double? longitude;
  final String? operatorName;

  /// The key id that signed this entry. Present when the manifest was
  /// signature-verified.
  final String? signedBy;
  final String? expiresAt;
  final List<String> notes;

  static Result<ManifestEntry> fromJson(Map<String, Object?> json) {
    final id = _string(json, 'id');
    if (id == null) {
      return _invalid('manifest.id', 'A manifest entry has no id.');
    }
    final hostname = _string(json, 'hostname');
    if (hostname == null) {
      return _invalid(
        'manifest.hostname',
        'Manifest entry "$id" has no hostname.',
      );
    }
    final country = _string(json, 'country')?.toUpperCase();
    if (country == null || !RegExp(r'^[A-Z]{2}$').hasMatch(country)) {
      return _invalid(
        'manifest.country',
        'Manifest entry "$id" needs a two-letter country code.',
      );
    }
    final protocol = switch (_string(json, 'protocol')) {
      'wireguard' => ProtocolKind.wireGuard,
      'openvpn' => ProtocolKind.openVpn,
      _ => null,
    };
    if (protocol == null) {
      return _invalid(
        'manifest.protocol',
        'Manifest entry "$id" has no valid protocol.',
      );
    }
    final endpoints = (json['endpoints'] as List<Object?>?)
        ?.map((e) => e?.toString() ?? '')
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
    if (endpoints == null || endpoints.isEmpty) {
      return _invalid(
        'manifest.endpoints',
        'Manifest entry "$id" has no endpoints.',
      );
    }
    final config = _string(json, 'config');
    if (config == null || config.isEmpty) {
      return _invalid(
        'manifest.config',
        'Manifest entry "$id" has no configuration.',
      );
    }
    final trust = switch (_string(json, 'trust')) {
      'project' => TrustLevel.projectVerified,
      'community' => TrustLevel.community,
      _ => TrustLevel.unknown,
    };

    return Ok(
      ManifestEntry(
        id: id,
        hostname: hostname,
        countryCode: country,
        protocol: protocol,
        endpoints: endpoints,
        config: config,
        trustLevel: trust,
        city: _string(json, 'city'),
        latitude: (json['latitude'] as num?)?.toDouble(),
        longitude: (json['longitude'] as num?)?.toDouble(),
        operatorName: _string(json, 'operator'),
        signedBy: _string(json, 'signed_by'),
        expiresAt: _string(json, 'expires_at'),
        notes:
            (json['notes'] as List<Object?>?)
                ?.map((e) => e?.toString() ?? '')
                .where((e) => e.isNotEmpty)
                .toList(growable: false) ??
            const [],
      ),
    );
  }

  static String? _string(Map<String, Object?> json, String key) {
    final value = json[key];
    return value is String && value.trim().isNotEmpty ? value.trim() : null;
  }

  static Result<ManifestEntry> _invalid(String code, String message) =>
      Err(AppError(group: ErrorGroup.provider, code: code, message: message));
}

/// Manifest configuration: the shape of the whole document.
class Manifest {
  const Manifest({
    required this.version,
    required this.entries,
    this.signedBy,
    this.signatureVerified = false,
    this.generatedAt,
  });

  final int version;
  final List<ManifestEntry> entries;
  final String? signedBy;
  final bool signatureVerified;
  final String? generatedAt;

  static const int currentVersion = 1;

  static Result<Manifest> fromJson(Map<String, Object?> json) {
    final version = (json['version'] as num?)?.toInt();
    if (version == null || version > currentVersion) {
      return const Err(
        AppError(
          group: ErrorGroup.provider,
          code: 'manifest.version',
          message: 'The server manifest is missing a supported version number.',
        ),
      );
    }
    final rawEntries = json['servers'];
    if (rawEntries is! List) {
      return const Err(
        AppError(
          group: ErrorGroup.provider,
          code: 'manifest.servers',
          message: 'The server manifest has no server list.',
        ),
      );
    }
    final entries = <ManifestEntry>[];
    for (final raw in rawEntries) {
      if (raw is! Map) {
        continue;
      }
      final entry = ManifestEntry.fromJson(raw.cast<String, Object?>());
      final value = entry.valueOrNull;
      if (value != null) {
        entries.add(value);
      }
    }
    return Ok(
      Manifest(
        version: version,
        entries: entries,
        signedBy: (json['signed_by'] as String?)?.trim(),
        signatureVerified: json['signature_verified'] == true,
        generatedAt: json['generated_at'] as String?,
      ),
    );
  }
}
