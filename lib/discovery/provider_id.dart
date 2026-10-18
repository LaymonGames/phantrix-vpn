part of 'discovery_controller.dart';

enum ProviderId {
  vpnGate('vpngate');

  const ProviderId(this.wireName);

  final String wireName;

  static ProviderId? fromWire(String value) {
    for (final id in ProviderId.values) {
      if (id.wireName == value) {
        return id;
      }
    }
    return null;
  }
}
