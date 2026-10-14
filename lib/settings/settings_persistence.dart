import 'dart:convert';

import 'package:phantrix_core/phantrix_core.dart';

import '../settings/settings_controller.dart';
import '../storage/app_store.dart';

/// Reads and writes [AppSettings] as JSON.
///
/// ## Why serialisation lives here and not in `AppSettings`
///
/// `AppSettings` is a value type in a pure-Dart package that must not depend
/// on anything. Serialising it is a concern of the app that owns the disk, and
/// putting it here keeps the core package free of I/O while still letting the
/// same field names be used on both sides.
///
/// ## Why every field is written out
///
/// Rather than a diff against the defaults, the whole object is written. A
/// diff would mean that removing a setting in a later version leaves it on
/// disk forever, and would make "which fields exist" a second, hidden list
/// that can drift from the type.
class SettingsCodec {
	const SettingsCodec._();

	static const String storageKey = 'settings';

	/// The stored form.
	static String encode(AppSettings settings) => jsonEncode({
		'preferredProtocol': settings.preferredProtocol,
		'killSwitch': settings.killSwitch.name,
		'strictMode': settings.strictMode,
		'dnsMode': settings.dnsMode.name,
		'customDns': settings.customDns,
		'ipv6': settings.ipv6.name,
		'autoConnect': settings.autoConnect.name,
		'autoSelectFastest': settings.autoSelectFastest,
		'autoSelectFavoriteCountry': settings.autoSelectFavoriteCountry,
		'autoSelectNearestCountry': settings.autoSelectNearestCountry,
		'reconnectAutomatically': settings.reconnectAutomatically,
		'startOnBoot': settings.startOnBoot,
		'startMinimised': settings.startMinimised,
		'mtuOverride': settings.mtuOverride,
		'protocolFallback': settings.protocolFallback,
		'themeMode': settings.themeMode,
		'animationLevel': settings.animationLevel,
		'language': settings.language,
		'trustedNetworks': settings.trustedNetworks,
		'favoriteCountries': settings.favoriteCountries,
		'selectedCountryCode': settings.selectedCountryCode,
		'favoriteServers': settings.favoriteServers,
		'recentServers': settings.recentServers,
		'logVerbosity': settings.logVerbosity.name,
		'diagnosticsOptIn': settings.diagnosticsOptIn,
		'clearedHistoryAt': settings.clearedHistoryAt?.toUtc().toIso8601String(),
		'onboardingComplete': settings.onboardingComplete,
		'privacyNoticeAccepted': settings.privacyNoticeAccepted,
	});

	/// Reads the stored form back.
	///
	/// A field that is missing, of the wrong type, or no longer a legal value
	/// falls back to its default instead of throwing. Settings are not worth
	/// refusing to launch over, and a value that was legal when it was written
	/// may not be legal now.
	static AppSettings decode(String raw) {
		Object? decoded;
		try {
			decoded = jsonDecode(raw);
		} on FormatException {
			return AppSettings.defaults;
		}
		if (decoded is! Map) {
			return AppSettings.defaults;
		}
		final d = AppSettings.defaults;
		return AppSettings(
			preferredProtocol: _enumOr(decoded['preferredProtocol'], d.preferredProtocol),
			killSwitch: _enum(decoded['killSwitch'], KillSwitchMode.values, d.killSwitch),
			strictMode: _bool(decoded['strictMode'], d.strictMode),
			dnsMode: _enum(decoded['dnsMode'], DnsMode.values, d.dnsMode),
			customDns: _strings(decoded['customDns'], d.customDns),
			ipv6: _enum(decoded['ipv6'], Ipv6Mode.values, d.ipv6),
			autoConnect: _enum(decoded['autoConnect'], AutoConnectPolicy.values, d.autoConnect),
			autoSelectFastest: _bool(decoded['autoSelectFastest'], d.autoSelectFastest),
			autoSelectFavoriteCountry:
					_bool(decoded['autoSelectFavoriteCountry'], d.autoSelectFavoriteCountry),
			autoSelectNearestCountry:
					_bool(decoded['autoSelectNearestCountry'], d.autoSelectNearestCountry),
			reconnectAutomatically:
					_bool(decoded['reconnectAutomatically'], d.reconnectAutomatically),
			startOnBoot: _bool(decoded['startOnBoot'], d.startOnBoot),
			startMinimised: _bool(decoded['startMinimised'], d.startMinimised),
			mtuOverride: _int(decoded['mtuOverride'], d.mtuOverride),
			protocolFallback: _bool(decoded['protocolFallback'], d.protocolFallback),
			themeMode: _oneOf(decoded['themeMode'], AppSettings.supportedThemes, d.themeMode),
			animationLevel:
					_oneOf(decoded['animationLevel'], AppSettings.supportedAnimationLevels, d.animationLevel),
			language: _oneOf(decoded['language'], AppSettings.supportedLanguages, d.language),
			trustedNetworks: _strings(decoded['trustedNetworks'], d.trustedNetworks),
			favoriteCountries: _strings(decoded['favoriteCountries'], d.favoriteCountries),
			selectedCountryCode: _countryCode(decoded['selectedCountryCode'], d.selectedCountryCode),
			favoriteServers: _strings(decoded['favoriteServers'], d.favoriteServers),
			recentServers: _strings(decoded['recentServers'], d.recentServers),
			logVerbosity: _enum(decoded['logVerbosity'], LogVerbosity.values, d.logVerbosity),
			diagnosticsOptIn: _bool(decoded['diagnosticsOptIn'], d.diagnosticsOptIn),
			clearedHistoryAt:
					DateTime.tryParse(decoded['clearedHistoryAt']?.toString() ?? '')?.toLocal() ??
					d.clearedHistoryAt,
			onboardingComplete: _bool(decoded['onboardingComplete'], d.onboardingComplete),
			privacyNoticeAccepted:
					_bool(decoded['privacyNoticeAccepted'], d.privacyNoticeAccepted),
		);
	}

	static T _enum<T extends Enum>(Object? value, List<T> allowed, T fallback) {
		if (value is! String) {
			return fallback;
		}
		for (final candidate in allowed) {
			if (candidate.name == value) {
				return candidate;
			}
		}
		return fallback;
	}

	static String? _enumOr(Object? value, String? fallback) =>
			value is String && value.isNotEmpty ? value : fallback;

	static String _oneOf(Object? value, Set<String> allowed, String fallback) =>
			value is String && allowed.contains(value) ? value : fallback;

	static String _countryCode(Object? value, String fallback) {
		if (value is! String || value.trim().isEmpty) {
			return fallback;
		}
		final code = value.trim().toUpperCase();
		if (code == 'AUTO') {
			return code;
		}
		// Keep one canonical form in settings. Directory feeds generally use
		// ISO-2 codes; preserving ISO-3 here would make a remembered selection
		// fail to match its server rows after restart.
		return GeoDatabase.byIso2(code)?.iso2 ?? GeoDatabase.byIso3(code)?.iso2 ?? fallback;
	}

	static bool _bool(Object? value, bool fallback) => value is bool ? value : fallback;

	static int? _int(Object? value, int? fallback) =>
			value is num && value == value.roundToDouble() ? value.toInt() : fallback;

	static List<String> _strings(Object? value, List<String> fallback) {
		if (value is! List) {
			return fallback;
		}
		return value.whereType<String>().toList();
	}
}

/// Loads settings at start-up and saves them on every change.
///
/// The controller stays a [ChangeNotifier] with the same [update] entry point
/// as before, so nothing above it has to know that persistence exists.
class PersistentSettingsController extends SettingsController {
	PersistentSettingsController(super.initial, this._store);

	final AppStore _store;

	/// Reads the stored settings, or the defaults when there are none.
	static Future<AppSettings> loadFrom(AppStore store) async {
		final raw = await store.read(SettingsCodec.storageKey);
		if (raw == null || raw.isEmpty) {
			return AppSettings.defaults;
		}
		return SettingsCodec.decode(raw);
	}

	@override
	void update(AppSettings Function(AppSettings) change) {
		super.update(change);
		// Fire and forget: the UI must not wait on a disk write, and a failed
		// write leaves the in-memory value correct. The store is written
		// atomically, so a partially written settings file cannot exist.
		_store.write(SettingsCodec.storageKey, SettingsCodec.encode(data));
	}
}
