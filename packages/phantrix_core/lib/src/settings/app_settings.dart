/// How traffic is prevented from escaping when the tunnel is down.
enum KillSwitchMode {
	/// No kill switch.
	off('Off'),

	/// Block what the platform allows; degrade gracefully when it cannot.
	automatic('Automatic'),

	/// Block everything that is not the tunnel. Where the platform cannot
	/// guarantee this, the setting reports that rather than pretending.
	strict('Strict');

	const KillSwitchMode(this.label);

	final String label;
}

/// Which DNS the device uses while connected.
enum DnsMode {
	/// The DNS the VPN server pushes. Recommended.
	vpn('VPN server DNS'),

	/// A well-known privacy resolver the user picks.
	trusted('Trusted resolver'),

	/// A resolver the user typed themselves.
	custom('Custom DNS');

	const DnsMode(this.label);

	final String label;
}

/// Whether IPv6 goes through the tunnel, is blocked, or follows the system.
enum Ipv6Mode {
	/// Route IPv6 only when the server supports it.
	preferTunnel('Route when supported'),

	/// Block IPv6 entirely while connected. This is the safe default: it is
	/// not a leak, and the app says so.
	block('Block while connected'),

	/// Follow whatever the system does. Explicitly labelled as a leak risk.
	allow('Allow (may leak)');

	const Ipv6Mode(this.label);

	final String label;
}

/// When the app connects by itself.
enum AutoConnectPolicy {
	/// Never.
	never('Only when I ask'),

	/// On app start.
	onAppStart('When the app starts'),

	/// On every network change.
	onEveryNetwork('On every network change'),

	/// Only on networks not on the trusted list.
	onUntrustedNetwork('On untrusted networks only'),

	/// Always.
	always('Always');

	const AutoConnectPolicy(this.label);

	final String label;
}

/// Logging verbosity. Debug still redacts secrets.
enum LogVerbosity {
	normal,
	debug,
}

/// The whole application settings model.
///
/// Immutable. Every change produces a new instance so the UI can diff and
/// persistence can be a single, atomic write.
class AppSettings {
	const AppSettings({
		this.preferredProtocol,
		this.killSwitch = KillSwitchMode.automatic,
		this.strictMode = false,
		this.dnsMode = DnsMode.vpn,
		this.customDns = const [],
		this.ipv6 = Ipv6Mode.block,
		this.autoConnect = AutoConnectPolicy.never,
		this.autoSelectFastest = true,
		this.autoSelectFavoriteCountry = true,
		this.autoSelectNearestCountry = false,
		this.reconnectAutomatically = true,
		this.startOnBoot = false,
		this.startMinimised = true,
		this.mtuOverride,
		this.protocolFallback = true,
		this.themeMode = 'system',
		this.animationLevel = 'full',
		this.language = 'en',
		this.trustedNetworks = const [],
		this.favoriteCountries = const [],
		this.selectedCountryCode = 'AUTO',
		this.favoriteServers = const [],
		this.recentServers = const [],
		this.logVerbosity = LogVerbosity.normal,
		this.diagnosticsOptIn = false,
		this.clearedHistoryAt,
		this.onboardingComplete = false,
		this.privacyNoticeAccepted = false,
	});

	/// `null` means "let the app pick". Never a hard requirement.
	final String? preferredProtocol;

	final KillSwitchMode killSwitch;
	final bool strictMode;
	final DnsMode dnsMode;
	final List<String> customDns;
	final Ipv6Mode ipv6;
	final AutoConnectPolicy autoConnect;

	/// Automatic selection preferences.
	final bool autoSelectFastest;
	final bool autoSelectFavoriteCountry;
	final bool autoSelectNearestCountry;

	final bool reconnectAutomatically;
	final bool startOnBoot;
	final bool startMinimised;

	/// MTU override. Null means platform default, which is the recommendation.
	final int? mtuOverride;

	/// Try the other protocol when the preferred one fails.
	final bool protocolFallback;

	final String themeMode;
	final String animationLevel;

	/// `en` or `ar`. The app is RTL-capable when `ar` is selected.
	final String language;

	final List<String> trustedNetworks;
	final List<String> favoriteCountries;

	/// Last country selected by the user. `AUTO` deliberately means the app
	/// may choose the best available server; this preference survives restarts.
	final String selectedCountryCode;
	final List<String> favoriteServers;

	/// Server ids, most recent first. Local only.
	final List<String> recentServers;

	final LogVerbosity logVerbosity;
	final bool diagnosticsOptIn;
	final DateTime? clearedHistoryAt;
	final bool onboardingComplete;
	final bool privacyNoticeAccepted;

	static const AppSettings defaults = AppSettings();

	static const Set<String> supportedLanguages = {'en', 'ar'};

	static const Set<String> supportedThemes = {'light', 'dark', 'system'};

	static const Set<String> supportedAnimationLevels = {'none', 'reduced', 'full'};

	bool get isRtl => language == 'ar';

	AppSettings copyWith({
		String? preferredProtocol,
		KillSwitchMode? killSwitch,
		bool? strictMode,
		DnsMode? dnsMode,
		List<String>? customDns,
		Ipv6Mode? ipv6,
		AutoConnectPolicy? autoConnect,
		bool? autoSelectFastest,
		bool? autoSelectFavoriteCountry,
		bool? autoSelectNearestCountry,
		bool? reconnectAutomatically,
		bool? startOnBoot,
		bool? startMinimised,
		int? mtuOverride,
		bool? protocolFallback,
		String? themeMode,
		String? animationLevel,
		String? language,
		List<String>? trustedNetworks,
		List<String>? favoriteCountries,
		String? selectedCountryCode,
		List<String>? favoriteServers,
		List<String>? recentServers,
		LogVerbosity? logVerbosity,
		bool? diagnosticsOptIn,
		DateTime? clearedHistoryAt,
		bool? onboardingComplete,
		bool? privacyNoticeAccepted,
	}) =>
			AppSettings(
				preferredProtocol: preferredProtocol ?? this.preferredProtocol,
				killSwitch: killSwitch ?? this.killSwitch,
				strictMode: strictMode ?? this.strictMode,
				dnsMode: dnsMode ?? this.dnsMode,
				customDns: customDns ?? this.customDns,
				ipv6: ipv6 ?? this.ipv6,
				autoConnect: autoConnect ?? this.autoConnect,
				autoSelectFastest: autoSelectFastest ?? this.autoSelectFastest,
				autoSelectFavoriteCountry: autoSelectFavoriteCountry ?? this.autoSelectFavoriteCountry,
				autoSelectNearestCountry: autoSelectNearestCountry ?? this.autoSelectNearestCountry,
				reconnectAutomatically: reconnectAutomatically ?? this.reconnectAutomatically,
				startOnBoot: startOnBoot ?? this.startOnBoot,
				startMinimised: startMinimised ?? this.startMinimised,
				mtuOverride: mtuOverride ?? this.mtuOverride,
				protocolFallback: protocolFallback ?? this.protocolFallback,
				themeMode: themeMode ?? this.themeMode,
				animationLevel: animationLevel ?? this.animationLevel,
				language: language ?? this.language,
				trustedNetworks: trustedNetworks ?? this.trustedNetworks,
				favoriteCountries: favoriteCountries ?? this.favoriteCountries,
				selectedCountryCode: selectedCountryCode ?? this.selectedCountryCode,
				favoriteServers: favoriteServers ?? this.favoriteServers,
				recentServers: recentServers ?? this.recentServers,
				logVerbosity: logVerbosity ?? this.logVerbosity,
				diagnosticsOptIn: diagnosticsOptIn ?? this.diagnosticsOptIn,
				clearedHistoryAt: clearedHistoryAt ?? this.clearedHistoryAt,
				onboardingComplete: onboardingComplete ?? this.onboardingComplete,
				privacyNoticeAccepted: privacyNoticeAccepted ?? this.privacyNoticeAccepted,
			);

	/// Whether the app should bring itself up when the network looks
	/// untrusted.
	bool shouldAutoConnect(String? networkName) => switch (autoConnect) {
		AutoConnectPolicy.never => false,
		AutoConnectPolicy.onAppStart => true,
		AutoConnectPolicy.onEveryNetwork => true,
		AutoConnectPolicy.always => true,
		AutoConnectPolicy.onUntrustedNetwork =>
			networkName == null || !trustedNetworks.contains(networkName),
	};
}
