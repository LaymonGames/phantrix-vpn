/// A traffic sample from the platform's tunnel interface.
class PlatformTraffic {
  const PlatformTraffic({
    required this.rxBytes,
    required this.txBytes,
    this.rxRate,
    this.txRate,
    this.lastHandshake,
    this.assignedIpv4,
    this.assignedIpv6,
    this.protocolLabel,
  });

  final int rxBytes;
  final int txBytes;
  final int? rxRate;
  final int? txRate;
  final DateTime? lastHandshake;
  final String? assignedIpv4;
  final String? assignedIpv6;
  final String? protocolLabel;

  static const PlatformTraffic empty = PlatformTraffic(rxBytes: 0, txBytes: 0);
}
