/// What the host can actually do, as reported by the native side.
///
/// The UI must never offer a control the platform reports as unsupported.
class PlatformCapabilities {
  const PlatformCapabilities({
    required this.platformName,
    required this.supportsKillSwitch,
    required this.supportsIpv6Blocking,
    required this.supportsVpnProvidedDns,
    required this.supportsPerAppSplitTunnelling,
    required this.supportsLanBypass,
    required this.supportsAlwaysOn,
    required this.supportsTray,
    required this.supportsBootStart,
    this.openVpn = false,
    this.systemLockdown = false,
    this.limitations = const {},
  });

  final String platformName;

  /// Whether the backend can block traffic itself when the tunnel drops.
  ///
  /// This is false on every platform today, and that is a deliberate
  /// statement rather than a missing feature flag: none of the backends
  /// installs a traffic-blocking rule that survives the tunnel interface.
  /// Android's genuine protection is the operating system's own Always-on
  /// VPN lockdown, which is reported separately as [systemLockdown] because
  /// it is a system setting the user controls, not something the app does.
  final bool supportsKillSwitch;
  final bool supportsIpv6Blocking;
  final bool supportsVpnProvidedDns;
  final bool supportsPerAppSplitTunnelling;
  final bool supportsLanBypass;
  final bool supportsAlwaysOn;
  final bool supportsTray;
  final bool supportsBootStart;

  /// Whether this host can actually start an OpenVPN tunnel, as reported
  /// by the native side (the bundled community `openvpn.exe` plus helper on
  /// Windows; always false on Android, which has no OpenVPN engine).
  ///
  /// False everywhere until a platform reports it, so an OpenVPN server is
  /// rejected with an explanation instead of being attempted and failing
  /// inside the engine. The Dart side never assumes it: an engine that is
  /// not there must not be advertised as one.
  final bool openVpn;

  /// Whether the operating system is currently blocking traffic outside a
  /// VPN itself (Android's Always-on VPN with "Block connections without
  /// VPN", pointing at this app).
  ///
  /// This is the only genuine kill switch on stock Android, and it belongs
  /// to the system settings, not to the app — which is why it is a separate
  /// reading rather than part of [supportsKillSwitch]. False everywhere
  /// except Android, and false on Android until the user enables it.
  final bool systemLockdown;

  /// Human-readable explanations of what this platform cannot do.
  final Map<String, String> limitations;

  static const PlatformCapabilities web = PlatformCapabilities(
    platformName: 'web',
    supportsKillSwitch: false,
    supportsIpv6Blocking: false,
    supportsVpnProvidedDns: false,
    supportsPerAppSplitTunnelling: false,
    supportsLanBypass: false,
    supportsAlwaysOn: false,
    supportsTray: false,
    supportsBootStart: false,
    limitations: {
      'kill_switch':
          'A browser cannot protect traffic outside itself. A system-wide '
          'client on Windows, macOS, Linux, Android or iOS is required.',
    },
  );
}
