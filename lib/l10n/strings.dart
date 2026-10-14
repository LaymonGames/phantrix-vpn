import 'package:flutter/widgets.dart';



/// English and Arabic strings used by the UI.
///
/// Every string the user can see lives here. Nothing is hardcoded in a widget,
/// because a right-to-left layout with Arabic names has to be testable, and
/// because the honest way to support a second language is to make the first
/// one structured.
class L10n {
	const L10n(this.languageCode);

	final String languageCode;

	bool get isRtl => languageCode == 'ar';

	static const L10n en = L10n('en');
	static const L10n ar = L10n('ar');

	static const List<Locale> supportedLocales = [Locale('en'), Locale('ar')];

	static L10n of(BuildContext context) {
		final locale = Localizations.localeOf(context);
		return locale.languageCode == 'ar' ? ar : en;
	}

	String get(String key) => _values[languageCode]?[key] ?? _values['en']![key] ?? key;

	static const Map<String, Map<String, String>> _values = {
		'en': {
			'appTitle': 'Phantrix',
			'home': 'Home',
			'server': 'Server',
			'actions': 'Actions',
			'locations': 'Locations',
			'diagnostics': 'Diagnostics',
			'privacy': 'Privacy',
			'settings': 'Settings',
			'connect': 'Connect',
			'connecting': 'Connecting…',
			'disconnect': 'Disconnect',
			'notConnected': 'Not connected',
			'connected': 'Connected',
			'quickConnect': 'Quick Connect',
			'chooseLocation': 'Choose Location',
			'automaticLocation': 'Automatic · best available',
			'automaticLocationHint': 'Let Phantrix choose the best eligible server.',
			'publicRelayNoticeTitle': 'The built-in public relays need OpenVPN support',
			'publicFeedOpenVpnOnly': 'The bundled public servers use OpenVPN, but this build currently connects through WireGuard only. Import a valid WireGuard .conf file with a reachable peer to connect.',
			'importWireGuardConfig': 'Import WireGuard config',
			'manageConfigurations': 'Manage configurations',
			'savedLocationHint': 'Saved preference · tap to change',
			'tapToChangeLocation': 'Tap to change location',
			'publicIp': 'Public IP',
			'vpnIp': 'VPN-assigned IP',
			'duration': 'Connected for',
			'protocol': 'Protocol',
			'download': 'Download',
			'upload': 'Upload',
			'tryAgain': 'Try again',
			'retry': 'Retry',
			'noServerInCountry': 'There is no usable server in this country right now.',
			'serversAvailable': 'servers available',
			'searchCountries': 'Search countries',
		'sortByName': 'Name',
		'sortByCount': 'Server count',
		'toggleMap': 'Show or hide the map',
		'refreshingServers': 'Refreshing the server list…',
		'serverListUnavailable': 'The server list could not be loaded.',
		'noServerListYet': 'No server list has been loaded yet.',
		'noServerListHint': 'Tap Refresh to ask the server sources for their current list.',
		'refresh': 'Refresh',
		'serverListStale': 'This server list is out of date.',
		'showingCachedList': 'Showing the last list that was loaded.',
		'cachedListDamaged': 'The saved server list was damaged and has been rebuilt.',
		'serverListCurrent': 'Server list is up to date.',
		'publicRelayWarning': 'Volunteer-run public relay. The operator can see your traffic, and it is not operated by this project.',
		'noServersFound': 'No servers were found. No connection can be made until at least one source returns a usable server.',
			'fastest': 'Fastest',
			'nearest': 'Nearest',
			'random': 'Random',
			'runChecks': 'Run checks',
			'amIProtected': 'Am I protected?',
			'leakExplanation':
				'Checking the public IP makes one request to a service that then '
				'knows the address your traffic appears to come from. Phantrix '
				'sends nothing else.',
			'notTested': 'Not tested',
			'notSupported': 'Not supported here',
			'checkPassed': 'Protected',
			'checkWarning': 'Warning',
			'checkFailed': 'Potential leak',
			'settingsConnection': 'Connection',
			'settingsPrivacy': 'Privacy',
			'settingsAppearance': 'Appearance',
			'settingsAdvanced': 'Advanced',
			'settingsAbout': 'About',
			'settingsConfigurations': 'Configurations',
			'settingsConfigurationsHint':
				'Import and connect to WireGuard configurations',
			'settingsDiagnostics': 'Diagnostics',
			'settingsDiagnosticsHint': 'Tunnel state, traffic and handshake evidence',
			'settingsPrivacyNotice': 'Privacy notice',
			'settingsPrivacyNoticeHint': 'What this app records, and what it does not',
			'settingsKillSwitchUnsupported':
				'Phantrix cannot block traffic itself when the tunnel drops. '
				'Automatic reconnects after a failure; it does not hold traffic '
				'back while reconnecting. The protection that exists is the '
				'system\u2019s own traffic blocking, shown below where '
				'the system provides one.',
			'settingsSystemLockdown': 'System traffic blocking',
			'settingsSystemLockdownOn': 'On',
			'settingsSystemLockdownOff': 'Off',
			'settingsSystemLockdownOnHint':
				'Android itself is blocking traffic outside the VPN. This is set '
				'in the system settings and stays in effect even if this app '
				'is closed.',
			'settingsSystemLockdownOffHint':
				'If the tunnel drops, traffic can leave over the normal network '
				'until the app reconnects. Enable Always-on VPN with Block '
				'connections without VPN in the system settings for protection '
				'that does not depend on this app running.',
			'settingsOpenVpnSettings': 'Open VPN settings',
			'killSwitch': 'Kill switch',
			'killSwitchOff': 'Off',
			'killSwitchAutomatic': 'Automatic',
			'killSwitchStrict': 'Strict',
			'dnsMode': 'DNS',
			'dnsVpn': 'VPN server DNS',
			'dnsTrusted': 'Trusted resolver',
			'dnsCustom': 'Custom DNS',
			'ipv6': 'IPv6',
			'ipv6Block': 'Block while connected',
			'ipv6Prefer': 'Route when supported',
			'ipv6Allow': 'Allow (may leak)',
			'autoConnect': 'Auto-connect',
			'reconnect': 'Reconnect automatically',
			'startOnBoot': 'Start on system boot',
			'debugLogging': 'Debug logging',
			'debugLoggingHint':
				'Debug logging stays redacted. Private keys and credentials are '
				'never written, even in debug mode.',
			'theme': 'Theme',
			'themeLight': 'Light',
			'themeDark': 'Dark',
			'themeSystem': 'System',
			'animation': 'Animation',
			'language': 'Language',
			'clearedata': 'Clear local data',
			'clearedataHint':
				'Removes settings, cached server lists, recent connections and '
				'imported configurations from this device.',
			'aboutVersion': 'Version',
			'aboutCreator': 'Creator',
			'aboutPortfolio': 'Portfolio',
			'portfolioOpenFailed':
				'Could not open the link. Visit '
				'laymongames.github.io/portfolio instead.',
			'viewLog': 'View log',
			'aboutDisclaimer':
				'You remain responsible for complying with applicable laws, '
				'network policies, and the terms of the networks and services you '
				'use.',
			'licensesTitle': 'Licenses & credits',
			'settingsLicenses': 'About, licenses and credits',
			'settingsLicensesHint':
				'Which components this app is built from, and under which '
				'licences',
			'licensesRepository': 'Source',
			'licensesAppLicense': 'Licence',
			'licensesCopyright': 'Copyright',
			'licensesSource': 'Source',
			'licensesProvenance': 'Licence read from',
			'licensesFullText': 'Full licence text',
			'licensesMissingText':
				'No licence text could be read for this component from local '
				'data. Use the source link or the provenance line above rather '
				'than assuming a licence.',
			'licensesGeneratedNote':
				'This inventory is generated from the project\u2019s lockfiles '
				'and build files by tools/generate_third_party_notices.dart. It '
				'is never edited by hand, and every line says where its fact '
				'came from.',
			'licensesSectionDart': 'Dart and Flutter packages',
			'licensesSectionAndroid': 'Android libraries',
			'licensesSectionWindows': 'Windows components',
			'licensesSectionAttribution': 'Adapted and bundled components',
			'licensesVpnGateTitle': 'VPN Gate',
			'licensesVpnGateBody':
				'Part of this app\u2019s built-in server list comes from the '
				'VPN Gate academic experiment (vpngate.net) at the University '
				'of Tsukuba. Those servers are run by volunteers: this project '
				'does not operate them, cannot vouch for them, and is not '
				'affiliated with VPN Gate or the university. The operator of '
				'any server you choose can see the traffic that leaves it.',
			'licensesNote_appLicenceScopeLimited':
				'This GPL-3.0-only notice applies to Phantrix\u2019s original code. '
				'Third-party components listed here keep their own licences. '
				'See docs/LICENSING_AUDIT.md.',
			'licensesNote_projectPackageScopeLimited':
				'This repository-local package contains original project code plus '
				'platform or bundled components that may have separate licence terms. '
				'The GPL-3.0-only grant applies only to independently authored Phantrix '
				'code; consult THIRD_PARTY_LICENSES.md and docs/LICENSING_AUDIT.md.',
			'licensesNote_devDependency':
				'Development and test only. It is not part of a released build.',
			'licensesNote_sdkDependency':
				'Part of the Flutter or Dart SDK. The displayed SDK file is an '
				'aggregate of multiple component notices, not a single licence grant.',
			'licensesNote_testOnly': 'Test only. It is not part of a released build.',
			'licensesNote_notBundled':
				'Not bundled with this build. Listed for completeness.',
			'licensesNote_shippedBinary': 'A compiled binary is bundled with this app.',
			'licensesNote_adaptedUpstream':
				'This project\u2019s code is an adaptation of the upstream '
				'project. The licence and copyright shown are upstream\u2019s.',
			'licensesNote_mereAggregation':
				'Windows-only aggregation: OpenVPN 2 is launched as a separate '
				'process, not linked into the app.',
			'licensesNote_variantUnclear':
				'The licence text establishes the GPL version but not whether '
				'\u201Cor any later version\u201D applies.',
			'licensesNote_licenceTextNotFound':
				'The licence name is known, but its full text is not bundled '
				'with this app.',
			'welcomeTitle': 'Private, simple, no account required.',
			'welcomeBody':
				"Phantrix routes this device's traffic through a VPN with no "
				'account, no email address, and no subscription.',
			'privacyNoticeTitle': 'What a VPN does and does not do',
			'privacyNoticeBody':
				'A VPN encrypts traffic between this device and the server it '
				'exits from. It does not make you anonymous, and the operator of '
				'a free public server can observe the traffic that leaves it.',
			'privacyNoticeAccept': 'I understand. Continue.',
		},
		'ar': {
			'appTitle': 'فيلجيت',
			'home': 'الرئيسية',
			'server': 'الخادم',
			'actions': 'الإجراءات',
			'locations': 'المواقع',
			'diagnostics': 'التشخيص',
			'privacy': 'الخصوصية',
			'settings': 'الإعدادات',
			'connect': 'اتصال',
			'connecting': 'جارٍ الاتصال…',
			'disconnect': 'قطع الاتصال',
			'notConnected': 'غير متصل',
			'connected': 'متصل',
			'quickConnect': 'اتصال سريع',
			'chooseLocation': 'اختر موقعًا',
			'automaticLocation': 'تلقائي · أفضل خادم متاح',
			'automaticLocationHint': 'دع التطبيق يختار أفضل خادم صالح.',
			'publicRelayNoticeTitle': 'الخوادم العامة المضمنة تحتاج إلى دعم OpenVPN',
			'publicFeedOpenVpnOnly': 'تستخدم الخوادم العامة المضمنة بروتوكول OpenVPN، بينما يعتمد هذا الإصدار حاليًا على WireGuard فقط. استورد ملف WireGuard صالحًا بامتداد .conf مع خادم متاح للاتصال.',
			'importWireGuardConfig': 'استيراد إعداد WireGuard',
			'manageConfigurations': 'إدارة الإعدادات المستوردة',
			'savedLocationHint': 'الموقع المحفوظ · اضغط للتغيير',
			'tapToChangeLocation': 'اضغط لتغيير الموقع',
			'publicIp': 'عنوانك العام',
			'vpnIp': 'عنوان الشبكة الافتراضية',
			'duration': 'مدة الاتصال',
			'protocol': 'البروتوكول',
			'download': 'تنزيل',
			'upload': 'تحميل',
			'tryAgain': 'أعد المحاولة',
			'retry': 'أعد المحاولة',
			'noServerInCountry': 'لا يوجد خادم صالح في هذه الدولة حاليًا.',
			'serversAvailable': 'خادمًا متاحًا',
			'searchCountries': 'ابحث عن دولة',
		'sortByName': 'الاسم',
		'sortByCount': 'عدد الخوادم',
		'toggleMap': 'إظهار الخريطة أو إخفاؤها',
		'refreshingServers': 'جارٍ تحديث قائمة الخوادم…',
		'serverListUnavailable': 'تعذر تحميل قائمة الخوادم.',
		'noServerListYet': 'لم يتم تحميل أي قائمة خوادم بعد.',
		'noServerListHint': 'اضغط «تحديث» لطلب القائمة الحالية من مصادر الخوادم.',
		'refresh': 'تحديث',
		'serverListStale': 'قائمة الخوادم هذه قديمة.',
		'showingCachedList': 'يتم عرض آخر قائمة تم تحميلها.',
		'cachedListDamaged': 'كانت قائمة الخوادم المحفوظة تالفة وأُعيد بناؤها.',
		'serverListCurrent': 'قائمة الخوادم محدثة.',
		'publicRelayWarning': 'خادم ترحيل تطوعي يشغّله طرف ثالث. يمكن للمشغّل رؤية حركة مرورك، ولا يديره هذا المشروع.',
		'noServersFound': 'لم يُعثر على أي خادم. لا يمكن إنشاء اتصال حتى يعيد مصدر واحد على الأقل خادمًا صالحًا.',
			'fastest': 'الأسرع',
			'nearest': 'الأقرب',
			'random': 'عشوائي',
			'runChecks': 'شغّل الفحوصات',
			'amIProtected': 'هل أنا محمي؟',
			'leakExplanation':
				'فحص العنوان العام يُرسل طلبًا واحدًا لخدمة تعرف بعدها العنوان '
				'الذي تظهر حركة بياناتك منه. لا يُرسل فيلجيت شيئًا آخر.',
			'notTested': 'لم يتم الاختبار',
			'notSupported': 'غير مدعوم هنا',
			'checkPassed': 'محمي',
			'checkWarning': 'تحذير',
			'checkFailed': 'تسريب محتمل',
			'settingsConnection': 'الاتصال',
			'settingsPrivacy': 'الخصوصية',
			'settingsAppearance': 'المظهر',
			'settingsAdvanced': 'متقدم',
			'settingsAbout': 'حول التطبيق',
			'killSwitch': 'مفتاح الإيقاف',
			'killSwitchOff': 'معطّل',
			'killSwitchAutomatic': 'تلقائي',
			'killSwitchStrict': 'صارم',
			'dnsMode': 'نظام أسماء النطاقات',
			'dnsVpn': 'خادم الشبكة الافتراضية',
			'dnsTrusted': 'خادم موثوق',
			'dnsCustom': 'نطاقات مخصصة',
			'ipv6': 'IPv6',
			'ipv6Block': 'الحظر أثناء الاتصال',
			'ipv6Prefer': 'التوجيه عند الدعم',
			'ipv6Allow': 'السماح (قد يسبب تسريبًا)',
			'autoConnect': 'الاتصال التلقائي',
			'reconnect': 'إعادة الاتصال تلقائيًا',
			'startOnBoot': 'التشغيل مع إقلاع النظام',
			'debugLogging': 'سجل التشخيص',
			'debugLoggingHint':
				'يبقى السجل مخفيًا للمعلومات الحساسة. لا تُكتب المفاتيح '
				'الخاصة أو بيانات الدخول أبدًا، حتى في وضع التشخيص.',
			'theme': 'السمة',
			'themeLight': 'فاتحة',
			'themeDark': 'داكنة',
			'themeSystem': 'النظام',
			'animation': 'الحركة',
			'language': 'اللغة',
			'clearedata': 'امسح البيانات المحلية',
			'clearedataHint':
				'يحذف الإعدادات وقوائم الخوادم المحفوظة وسجل الاتصالات '
				'والإعدادات المستوردة من هذا الجهاز.',
			'aboutVersion': 'الإصدار',
			'aboutCreator': 'المنشئ',
			'aboutPortfolio': 'معرض الأعمال',
			'portfolioOpenFailed':
				'تعذّر فتح الرابط. زيّر '
				'laymongames.github.io/portfolio بدلاً من ذلك.',
			'viewLog': 'اعرض السجل',
			'aboutDisclaimer':
				'تبقى مسؤولية الالتزام بالقوانين المعمول بها وسياسات الشبكات '
				'وشروط الخدمات التي تستخدمها عليك.',
			'licensesTitle': 'التراخيص والإشادات',
			'settingsLicenses': 'حول التطبيق والتراخيص والإشادات',
			'settingsLicensesHint':
				'المكوّنات التي بُني منها هذا التطبيق، والتراخيص التي تخضع لها',
			'licensesRepository': 'المصدر',
			'licensesAppLicense': 'الترخيص',
			'licensesCopyright': 'حقوق النشر',
			'licensesSource': 'المصدر',
			'licensesProvenance': 'مصدر نص الترخيص',
			'licensesFullText': 'نص الترخيص الكامل',
			'licensesMissingText':
				'لم يُعثر على نص ترخيص لهذا المكوّن في البيانات المحلية. '
				'استخدم رابط المصدر أو سطر المصدر أعلاه بدلًا من افتراض ترخيص.',
			'licensesGeneratedNote':
				'تُولَّد هذه القائمة من ملفات القفل وملفات البناء في المشروع '
				'عبر tools/generate_third_party_notices.dart. لا تُعدَّل '
				'يدويًا، وكل سطر يذكر مصدر معلومته.',
			'licensesSectionDart': 'حزم Dart وFlutter',
			'licensesSectionAndroid': 'مكتبات أندرويد',
			'licensesSectionWindows': 'مكوّنات ويندوز',
			'licensesSectionAttribution': 'مكوّنات مقتبسة ومُرفقة',
			'licensesVpnGateTitle': 'VPN Gate',
			'licensesVpnGateBody':
				'جزء من قائمة الخوادم المضمنة في هذا التطبيق مأخوذ من مشروع '
				'VPN Gate الأكاديمي (vpngate.net) في جامعة تسوكوبا. تشغّل تلك '
				'الخوادم فرق تطوعية: لا يديرها هذا المشروع، ولا يستطيع ضمانها، '
				'ولا يرتبط بـ VPN Gate أو بالجامعة. يستطيع مشغّل أي خادم تختاره '
				'رؤية حركة البيانات التي تخرج منه.',
			'licensesNote_appLicenceScopeLimited':
				'ينطبق هذا الإشعار الخاص بـ GPL-3.0-only على شيفرة Phantrix الأصلية. '
				'تحتفظ المكونات الخارجية المدرجة هنا بتراخيصها الخاصة. '
				'راجع docs/LICENSING_AUDIT.md.',
			'licensesNote_projectPackageScopeLimited':
				'تحتوي هذه الحزمة المحلية على شيفرة أصلية للمشروع إلى جانب مكونات '
				'للمنصات أو مكونات مضمّنة قد تخضع لشروط ترخيص منفصلة. ينطبق ترخيص '
				'GPL-3.0-only على شيفرة Phantrix المكتوبة بصورة مستقلة فقط. راجع '
				'THIRD_PARTY_LICENSES.md وdocs/LICENSING_AUDIT.md.',
			'licensesNote_devDependency':
				'للتطوير والاختبار فقط، وليس جزءًا من الإصدار النهائي.',
			'licensesNote_sdkDependency':
				'جزء من Flutter أو Dart SDK. الملف المعروض يجمع إشعارات تراخيص '
				'مكونات متعددة، وليس منحة ترخيص واحدة.',
			'licensesNote_testOnly':
				'للاختبار فقط، وليس جزءًا من الإصدار النهائي.',
			'licensesNote_notBundled':
				'غير مرفق بهذا الإصدار، ومذكور لإكمال الصورة.',
			'licensesNote_shippedBinary':
				'يُرافق هذا التطبيق ملف تنفيذي مُصرَّف مسبقًا.',
			'licensesNote_adaptedUpstream':
				'شيفرة هذا المشروع مقتبسة من المشروع الأصلي، والترخيص وحقوق '
				'النشر المعروضة هي للمشروع الأصلي.',
			'licensesNote_mereAggregation':
				'يقتصر التجميع المنفصل على Windows: تُشغّل OpenVPN 2 كعملية مستقلة '
				'غير مرتبطة بالتطبيق.',
			'licensesNote_variantUnclear':
				'يحدَّد نص الترخيص إصدار GPL دون أن يوضح ما إذا كان '
				'«أو أي إصدار لاحق» ينطبق.',
			'licensesNote_licenceTextNotFound':
				'اسم الترخيص معروف، لكن نصه الكامل غير مرفق بهذا التطبيق.',
			'welcomeTitle': 'خصوصية وبساطة، بلا حساب.',
			'welcomeBody':
				'يوجّه فيلجيت حركة بيانات هذا الجهاز عبر شبكة افتراضية بلا '
				'حساب ولا بريد إلكتروني ولا اشتراك.',
			'privacyNoticeTitle': 'ما تفعله الشبكة الافتراضية وما لا تفعله',
			'privacyNoticeBody':
				'تُشفّر الشبكة الافتراضية البيانات بين هذا الجهاز والخادم '
				'الذي يخرج منه. إنها لا تجعلك مجهول الهوية، ويستطيع مشغّل '
				'خادم عام مجاني مراقبة ما يخرج منه.',
			'privacyNoticeAccept': 'فهمت، تابع.',
		},
	};
}
