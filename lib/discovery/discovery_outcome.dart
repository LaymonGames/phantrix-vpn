part of 'discovery_controller.dart';

class _Outcome {
  const _Outcome(
    this.providerId,
    this.servers, {
    required this.usedCache,
    required this.fetchedAt,
  });

  final String providerId;
  final List<VpnServer> servers;
  final bool usedCache;
  final DateTime? fetchedAt;
}
