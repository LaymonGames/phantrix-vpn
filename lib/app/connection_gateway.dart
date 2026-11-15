part of 'app_shell.dart';

/// Adapts [ConnectionController] to what the diagnostics screen needs.
class _ConnectionGateway implements ConnectionControllerLike {
  _ConnectionGateway(this._controller);

  final ConnectionController _controller;

  @override
  Future<PlatformCapabilities> capabilities() async => _controller.capabilities;

  @override
  bool get isConnected => _controller.currentView.isConnected;

  @override
  String? get verifiedExitIp => _controller.currentView.session.assignedIpv4;

  @override
  bool get killSwitchActive => _controller.currentView.killSwitch.active;

  @override
  String? get killSwitchMode => _controller.currentView.killSwitch.mode;

  @override
  Future<String?> readPublicIp() => _controller.readPublicIp();
}
