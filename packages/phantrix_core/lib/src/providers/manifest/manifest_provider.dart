import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import '../../core/app_error.dart';
import '../../model/server_status.dart';
import '../../model/vpn_server.dart';
import '../../protocol/openvpn/ovpn_parser.dart';
import '../../protocol/openvpn/ovpn_validator.dart';
import '../../protocol/protocol_kind.dart';
import '../../protocol/vpn_configuration.dart';
import '../../protocol/wireguard/wg_parser.dart';
import '../../protocol/wireguard/wg_validator.dart';
import '../common/http_fetcher.dart';
import '../common/provider_capabilities.dart';
import '../common/server_provider.dart';
import 'manifest_schema.dart';

/// Reads a project (or community) server manifest.
///
/// The manifest is fetched over HTTPS from a configured endpoint. Every entry
/// is parsed and security-checked exactly the way a user import is, so a
/// compromised manifest can only add servers that already pass the same rules.
///
/// When a detached Ed25519 signature and the matching public key are both
/// configured, [Manifest.signatureVerified] is true and servers are labelled
/// as signed. Otherwise the servers are still offered at their declared trust
/// level, but the UI explicitly says the list was not verified.
class ManifestProvider implements ServerProvider {
  ManifestProvider({
    required this.fetcher,
    required this.manifestUrl,
    this.signatureUrl,
    this.trustedSigningKey,
  });

  @override
  final HttpFetcher fetcher;

  final String manifestUrl;

  /// Optional detached signature for the manifest body.
  final String? signatureUrl;

  /// Base64 Ed25519 public key that [signatureUrl] must verify against.
  /// When null, the manifest is treated as unsigned.
  final String? trustedSigningKey;

  @override
  String get id => 'manifest';

  @override
  String get label => 'Project server list';

  @override
  ProviderCapabilities get capabilities => const ProviderCapabilities(
    servesConfigurations: true,
    supportsRefresh: true,
    supportsAutoDiscovery: true,
    protocols: {ProtocolKind.wireGuard, ProtocolKind.openVpn},
  );

  @override
  bool get autoRefresh => true;

  @override
  String get trustDescription =>
      'A list of servers published by the project or reviewed community operators.';

  final Map<String, ({String raw, VpnConfiguration config})> _configs = {};

  @override
  Future<RefreshOutcome> refresh({bool force = false}) async {
    if (manifestUrl.trim().isEmpty) {
      return RefreshOutcome.failure(
        const AppError(
          group: ErrorGroup.provider,
          code: 'manifest.not_configured',
          message: 'No server list endpoint is configured.',
        ),
      );
    }

    final Uri uri;
    try {
      uri = Uri.parse(manifestUrl.trim());
    } on FormatException {
      return RefreshOutcome.failure(
        const AppError(
          group: ErrorGroup.provider,
          code: 'manifest.bad_url',
          message: 'The configured server list endpoint is not a valid URL.',
        ),
      );
    }
    if (uri.scheme != 'https') {
      return RefreshOutcome.failure(
        const AppError(
          group: ErrorGroup.provider,
          code: 'manifest.insecure_url',
          message: 'Server lists are only fetched over HTTPS.',
        ),
      );
    }

    final String body;
    try {
      body = await fetcher.get(uri);
    } on AppError catch (error) {
      return RefreshOutcome.failure(error);
    } on BodyTooLargeException catch (error) {
      return RefreshOutcome.failure(error.asError());
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      return RefreshOutcome.failure(
        const AppError(
          group: ErrorGroup.provider,
          code: 'manifest.invalid_json',
          message: 'The server list could not be read as JSON.',
        ),
      );
    }
    if (decoded is! Map<String, Object?>) {
      return RefreshOutcome.failure(
        const AppError(
          group: ErrorGroup.provider,
          code: 'manifest.shape',
          message: 'The server list does not have the expected shape.',
        ),
      );
    }

    final manifest = Manifest.fromJson(decoded);
    final value = manifest.valueOrNull;
    if (value == null) {
      return RefreshOutcome.failure(manifest.errorOrNull!);
    }

    final signed = await SignatureVerifier.verifyManifest(
      fetcher: fetcher,
      body: body,
      signatureUrl: signatureUrl,
      publicKeyBase64: trustedSigningKey,
    );

    final servers = <VpnServer>[];
    final configs = <String, ({String raw, VpnConfiguration config})>{};
    final now = DateTime.now();

    for (final entry in value.entries) {
      final accepted = _accept(entry);
      if (accepted == null) {
        continue;
      }
      configs[entry.id] = accepted;
      servers.add(
        VpnServer(
          id: entry.id,
          hostname: entry.hostname,
          hostAddress: null,
          port: null,
          protocol: entry.protocol,
          trustLevel: entry.trustLevel,
          status: ServerStatus.unknown,
          countryCode: entry.countryCode,
          providerId: id,
          city: entry.city,
          latitude: entry.latitude,
          longitude: entry.longitude,
          operatorName: entry.operatorName,
          firstSeenAt: now,
          lastSeenAt: now,
          fingerprint: entry.id,
          notes: [
            ...entry.notes,
            if (!signed)
              'This server list does not carry a signature that could be '
                  'verified, so treat it as unverified.',
          ],
        ),
      );
    }

    _configs
      ..clear()
      ..addAll(configs);

    return RefreshOutcome(servers: servers, usedCache: false, fetchedAt: now);
  }

  @override
  Future<ProviderConfig?> fetchConfig(String serverId) async {
    final entry = _configs[serverId];
    if (entry == null) {
      return null;
    }
    return ProviderConfig(
      providerId: id,
      rawText: entry.raw,
      validated: entry.config,
    );
  }

  ({String raw, VpnConfiguration config})? _accept(ManifestEntry entry) {
    switch (entry.protocol) {
      case ProtocolKind.wireGuard:
        final parsed = WgParser.parse(entry.config).valueOrNull;
        if (parsed == null) {
          return null;
        }
        final validated = WgValidator.validate(parsed).valueOrNull;
        if (validated == null) {
          return null;
        }
        final expanded = WgValidator.applyFullTunnel(validated.config);
        final revalidated = WgValidator.validate(expanded).valueOrNull;
        if (revalidated == null) {
          return null;
        }
        return (
          raw: entry.config,
          config: VpnConfiguration.wireGuard(revalidated),
        );
      case ProtocolKind.openVpn:
        final parsed = OvpnParser.parse(entry.config).valueOrNull;
        if (parsed == null) {
          return null;
        }
        final validated = OvpnValidator.validate(parsed).valueOrNull;
        if (validated == null) {
          return null;
        }
        return (raw: entry.config, config: VpnConfiguration.openVpn(validated));
    }
  }
}

/// Verifies a detached Ed25519 signature over a manifest body.
///
/// Uses `package:cryptography`'s Ed25519 implementation, which is backed by
/// a vetted native library on the platforms where one exists and a pure Dart
/// implementation elsewhere. No bespoke signature code is used.
class SignatureVerifier {
  const SignatureVerifier._();

  static final Ed25519 _algorithm = Ed25519();

  /// Verifies [body] against a detached signature.
  ///
  /// Returns false — never throws — when anything is missing or malformed.
  static Future<bool> verifyManifest({
    required HttpFetcher fetcher,
    required String body,
    required String? signatureUrl,
    required String? publicKeyBase64,
  }) async {
    final url = signatureUrl?.trim();
    final key = publicKeyBase64?.trim();
    if (url == null || url.isEmpty || key == null || key.isEmpty) {
      return false;
    }
    final Uri uri;
    try {
      uri = Uri.parse(url);
    } on FormatException {
      return false;
    }
    final String signatureText;
    try {
      signatureText = await fetcher.get(uri);
    } on AppError {
      return false;
    } on BodyTooLargeException {
      return false;
    }
    final List<int> signature;
    final List<int> publicKey;
    try {
      signature = base64Url.decode(signatureText.trim().replaceAll('\n', ''));
      publicKey = base64Url.decode(key.replaceAll('\n', ''));
    } on FormatException {
      return false;
    }
    if (signature.length != 64 || publicKey.length != 32) {
      return false;
    }
    try {
      final publicKeyObject = SimplePublicKey(
        publicKey,
        type: KeyPairType.ed25519,
      );
      final isValid = await _algorithm.verify(
        utf8.encode(body),
        signature: Signature(signature, publicKey: publicKeyObject),
      );
      return isValid;
    } on Object {
      return false;
    }
  }
}
