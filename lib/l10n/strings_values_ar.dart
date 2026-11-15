part of 'strings.dart';

const Map<String, String> _stringsValuesAr = {
  'appTitle': 'Phantrix',
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
  'chooseLocation': 'اختر موقعًا',
  'automaticLocation': 'تلقائي · أفضل خادم متاح',
  'automaticLocationHint': 'دع التطبيق يختار أفضل خادم صالح.',
  'publicRelayNoticeTitle': 'الخوادم العامة المضمنة تحتاج إلى دعم OpenVPN',
  'publicFeedOpenVpnOnly':
      'تستخدم الخوادم العامة المضمنة بروتوكول OpenVPN، ولا يتوفر محرك '
      'OpenVPN على هذه المنصة، لذا لا يمكن الاتصال بأي منها.',
  'savedLocationHint': 'الموقع المحفوظ · اضغط للتغيير',
  'tapToChangeLocation': 'اضغط لتغيير الموقع',
  'tryAgain': 'أعد المحاولة',
  'retry': 'أعد المحاولة',
  'noServerInCountry': 'لا يوجد خادم صالح في هذه الدولة حاليًا.',
  'serversAvailable': 'خادمًا متاحًا',
  'searchCountries': 'ابحث عن دولة',
  'sortByName': 'الاسم',
  'sortByCount': 'عدد الخوادم',
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
      'الذي تظهر حركة بياناتك منه. لا يُرسل Phantrix شيئًا آخر.',
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
  'settingsSplitTunneling': 'تقسيم النفق',
  'settingsSplitTunnelingHint': 'اختر التطبيقات التي تستخدم VPN',
  'settingsSplitTunnelingApps': 'التطبيقات ووضع التوجيه',
  'splitEnable': 'تفعيل تقسيم النفق',
  'splitEnableHint': 'تُطبَّق قواعد التوجيه فقط أثناء اتصال النفق.',
  'splitMode': 'وضع التوجيه',
  'splitModeInclude': 'التطبيقات المحددة فقط تستخدم VPN',
  'splitModeExclude': 'التطبيقات المحددة تتجاوز VPN',
  'splitModeIncludeHint': 'كل ما عداها يستخدم اتصالك العادي.',
  'splitModeExcludeHint': 'كل ما عداها يستخدم VPN.',
  'splitSearchHint': 'ابحث عن التطبيقات',
  'splitSearchClear': 'مسح البحث',
  'splitBrowse': 'اختيار ملف .exe',
  'splitSaved': 'تم حفظ تقسيم النفق.',
  'splitLiveApplied': 'طُبِّقت القواعد على النفق الحالي.',
  'splitApplyFailed': 'لم تُطبَّق قواعد التوجيه: {message}',
  'splitUnsupported':
      'يحتاج تقسيم النفق إلى مكوّن التوجيه المرفق، وهو غير متوفر في هذه '
      'النسخة أو على هذه المنصة.',
  'splitNeedsApps':
      'اختر تطبيقًا واحدًا على الأقل، أو أوقف تقسيم النفق.',
  'splitSelected': 'المحدد: {count}',
  'splitNoSelection': 'لم تُحدَّد تطبيقات',
  'splitNoMatches': 'لا توجد تطبيقات مطابقة.',
  'splitLoading': 'جارٍ البحث عن التطبيقات المثبّتة…',
  'splitEmpty': 'لم يُعثر على تطبيقات. استخدم «اختيار ملف .exe» لإضافة واحد.',
  'splitRemove': 'إزالة',
  'splitMissingHint':
      'تُتجاهل التطبيقات التي أُزيلت عند تطبيق القواعد.',
  'splitAppsUseVpn': 'التطبيقات المحددة تستخدم VPN',
  'splitAppsBypassVpn': 'التطبيقات المحددة تستخدم اتصالك العادي',
  'settingsDiagnostics': 'التشخيص',
  'settingsDiagnosticsHint': 'حالة النفق وحركة البيانات وأدلة المصافحة',
  'settingsPrivacyNotice': 'إشعار الخصوصية',
  'settingsPrivacyNoticeHint': 'ما يسجّله هذا التطبيق وما لا يسجّله',
  'settingsKillSwitchUnsupported':
      'لا يستطيع Phantrix حجب حركة البيانات بنفسه على هذا الجهاز، لذا '
      'إذا سقط النفق تخرج الحركة عبر الاتصال العادي حتى تعيد الاتصال. '
      'الحماية المتوفرة هي حجب النظام نفسه لحركة البيانات، الموضّح أدناه '
      'حيث يوفّره النظام.',
  'settingsSystemLockdown': 'حجب النظام لحركة البيانات',
  'settingsSystemLockdownOn': 'مفعّل',
  'settingsSystemLockdownOff': 'معطّل',
  'settingsSystemLockdownOnHint':
      'يحجب Android نفسه حركة البيانات خارج VPN. يُضبط ذلك في إعدادات '
      'النظام ويبقى ساريًا حتى لو أُغلق هذا التطبيق.',
  'settingsSystemLockdownOffHint':
      'إذا سقط النفق، قد تخرج البيانات عبر الشبكة العادية حتى يعيد '
      'التطبيق الاتصال. فعّل «VPN دائم التشغيل» مع «حجب الاتصالات بدون '
      'VPN» في إعدادات النظام لحماية لا تعتمد على تشغيل هذا التطبيق.',
  'settingsOpenVpnSettings': 'فتح إعدادات VPN',
  'killSwitch': 'مفتاح الإيقاف',
  'homeHeadIdle': 'أنت غير محمي',
  'homeHeadWorking': 'جارٍ تأمين اتصالك',
  'homeHeadConnected': 'أنت محمي',
  'homeHeadFailed': 'فشل الاتصال',
  'homeHeadBlocked': 'مطلوب إجراء',
  'homeSubIdle': 'تمر حركة بياناتك حاليًا عبر اتصال الإنترنت العادي.',
  'homeSubWorking': 'جارٍ بناء نفق مشفّر إلى {location}…',
  'homeSubConnected': 'حركة بياناتك مشفّرة عبر {location}.',
  'homeSubFailed': 'لم يتغير شيء. أعد المحاولة أو اختر موقعًا آخر.',
  'homeSubBlocked': 'هناك ما يحتاج إلى انتباهك قبل الاتصال.',
  'protectionTitle': 'الحماية',
  'protectionKillSwitch': 'مفتاح الإيقاف',
  'protectionSplit': 'تقسيم النفق',
  'protectionDns': 'DNS',
  'protectionDnsValue': 'عبر النفق',
  'protectionIpv6': 'IPv6',
  'protectionOff': 'متوقف',
  'protectionUnavailable': 'غير متاح',
  'protectionSplitInclude': '{count} تطبيقات عبر VPN',
  'protectionSplitExclude': '{count} تطبيقات خارج VPN',
  'protectionManage': 'الإدارة في الإعدادات',
  'killSwitchOff': 'معطّل',
  'killSwitchAutomatic': 'تلقائي',
  'killSwitchStrict': 'صارم',
  'killSwitchOffHint':
      'بلا حجب. إذا انقطع اتصال VPN تمرّ الحركة عبر اتصالك العادي.',
  'killSwitchAutomaticHint':
      'يحجب الإنترنت خارج VPN من لحظة الاتصال حتى تضغط قطع الاتصال. إذا '
      'انقطع الاتصال يبقى الإنترنت محجوبًا حتى تعيد الاتصال أو تلغي الحجب. '
      'إغلاق Phantrix يرفع الحجب. ما دام لا يوجد نفق، تبقى استعلامات DNS '
      'مسموحة حتى يصل Phantrix إلى قائمة الخوادم؛ أما تصفح الويب فيبقى '
      'محجوبًا.',
  'killSwitchStrictHint':
      'مثل الوضع التلقائي، لكن الإنترنت يبقى محجوبًا أيضًا بعد قطع الاتصال '
      'وبعد إغلاق Phantrix وبعد إعادة التشغيل، حتى تتصل من جديد أو تلغي '
      'الحجب أو تعطّل مفتاح الإيقاف. تبقى استعلامات DNS مسموحة حتى يصل '
      'Phantrix إلى قائمة الخوادم؛ أما تصفح الويب فيبقى محجوبًا. وتبقى أجهزة '
      'الشبكة المحلية كالطابعات متاحة.',
  'killSwitchStrictConfirmTitle': 'تفعيل مفتاح الإيقاف الصارم؟',
  'killSwitchStrictConfirmBody':
      'سيُحجب تصفح الويب وكل اتصال آخر بالإنترنت ما دام Phantrix غير متصل — '
      'حتى بعد إغلاق Phantrix أو إعادة تشغيل الحاسوب. تبقى استعلامات DNS '
      'مسموحة حتى يصل Phantrix إلى قائمة الخوادم. لا يعيد الإنترنت إلا '
      'الاتصال، أو إلغاء الحجب، أو تحويل مفتاح الإيقاف إلى معطّل أو تلقائي. '
      'على Windows يتطلب هذا التحويل موافقة المسؤول.\n\nتبقى أجهزة الشبكة '
      'المحلية كالطابعات متاحة. أوقف الوضع الصارم قبل إلغاء تثبيت '
      'Phantrix.',
  'killSwitchStrictConfirm': 'تفعيل الوضع الصارم',
  'killSwitchReleaseFailed':
      'تعذّر رفع حجب مفتاح الإيقاف، لذا ما زال الإنترنت محجوبًا. أعد '
      'المحاولة أو اتصل.',
  'homeKillSwitchStrict':
      'مفتاح الإيقاف الصارم: الإنترنت محجوب ما دمت غير متصل',
  'homeKillSwitchAutomatic':
      'انقطع الاتصال — مفتاح الإيقاف يحجب الإنترنت حتى تعيد الاتصال',
  'homeKillSwitchUnblock': 'إلغاء حجب الإنترنت',
  'homeKillSwitchUnblocking': 'جارٍ إلغاء الحجب…',
  'ipv6': 'IPv6',
  'ipv6Block': 'الحظر أثناء الاتصال',
  'ipv6Prefer': 'التوجيه عند الدعم',
  'ipv6Allow': 'السماح (قد يسبب تسريبًا)',
  'startOnBoot': 'التشغيل مع إقلاع النظام',
  'settingsBootStartUnsupported':
      'لا تستطيع هذه المنصة تشغيل التطبيق عند إقلاع النظام.',
  'settingsBootStartFailed':
      'تعذّر كتابة إدخال بدء التشغيل، لذا لن يبدأ التطبيق عند إقلاع النظام.',
  'theme': 'السمة',
  'themeLight': 'فاتحة',
  'themeDark': 'داكنة',
  'themeSystem': 'النظام',
  'animation': 'الحركة',
  'animationFull': 'كاملة',
  'animationReduced': 'مخفّفة',
  'animationNone': 'متوقفة',
  'accentColor': 'لون التمييز',
  'accentHint':
      'يُستخدم للأزرار والمفاتيح والتحديدات. تحتفظ حالة الاتصال بألوانها '
      'الخاصة.',
  'accent.green': 'أخضر Phantrix',
  'accent.jade': 'يشمي',
  'accent.teal': 'فيروزي',
  'accent.sky': 'سماوي',
  'accent.indigo': 'نيلي',
  'accent.violet': 'بنفسجي',
  'accent.rose': 'وردي',
  'accent.amber': 'كهرماني',
  'accent.custom': 'لون مخصّص',
  'accentCustomTitle': 'لون تمييز مخصّص',
  'accentHue': 'درجة اللون',
  'accentUse': 'استخدم هذا اللون',
  'accentReset': 'العودة إلى أخضر Phantrix',
  'language': 'اللغة',
  'clearData': 'امسح البيانات المحلية',
  'clearDataHint':
      'يحذف الإعدادات وقوائم الخوادم المحفوظة وسجل الاتصالات '
      'من هذا الجهاز.',
  'clearDataAction': 'مسح',
  'clearDataDone': 'تم مسح البيانات المحلية.',
  'aboutVersion': 'الإصدار',
  'aboutVersionUnknown': 'غير معروف',
  'aboutCreator': 'المنشئ',
  'aboutPortfolio': 'معرض الأعمال',
  'portfolioOpenFailed':
      'تعذّر فتح الرابط. زيّر '
      'laymongames.github.io/portfolio بدلاً من ذلك.',
  'aboutDisclaimer':
      'تبقى مسؤولية الالتزام بالقوانين المعمول بها وسياسات الشبكات '
      'وشروط الخدمات التي تستخدمها عليك.',
  'licensesTitle': 'التراخيص والإشادات',
  'licensesIntro':
      'Phantrix برنامج حر: يمكنك إعادة توزيعه و/أو تعديله وفق شروط '
      'GNU General Public License كما نشرتها مؤسسة البرمجيات الحرة، '
      'النسخة 3 فقط. ويأتي دون أي ضمان، إلى الحد الذي يسمح به القانون. '
      'وتعرض هذه الصفحة نص تلك الرخصة وكل مكوّن دخل في بناء هذا الإصدار.',
  'licensesAppHeading': 'هذا التطبيق',
  'licensesSearchHint': 'ابحث عن مكوّن أو إصدار أو ترخيص',
  'licensesSearchClear': 'امسح البحث',
  'licensesEmptyTitle': 'لا نتائج مطابقة',
  'licensesEmptyBody':
      'لم يُعثر على أي مكوّن أو إصدار أو ترخيص يطابق «{query}».',
  'licensesOpenLink': 'افتح في المتصفح',
  'licensesOpenFailed': 'تعذّر فتح الرابط.',
  'licensesFrameworkTitle': 'Flutter وDart SDK',
  'licensesFrameworkHint':
      'الإشادات المرفقة بالمحرك وإطار العمل اللذين بُني عليهما هذا التطبيق',
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
  'licensesSectionAndroid': 'مكتبات Android',
  'licensesSectionWindows': 'مكوّنات Windows',
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
  'licensesNote_testOnly': 'للاختبار فقط، وليس جزءًا من الإصدار النهائي.',
  'licensesNote_notBundled': 'غير مرفق بهذا الإصدار، ومذكور لإكمال الصورة.',
  'licensesNote_shippedBinary': 'يُرافق هذا التطبيق ملف تنفيذي مُصرَّف مسبقًا.',
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
      'يوجّه Phantrix حركة بيانات هذا الجهاز عبر شبكة افتراضية بلا '
      'حساب ولا بريد إلكتروني ولا اشتراك.',
  'privacyNoticeTitle': 'ما تفعله الشبكة الافتراضية وما لا تفعله',
  'privacyNoticeBody':
      'تُشفّر الشبكة الافتراضية البيانات بين هذا الجهاز والخادم '
      'الذي يخرج منه. إنها لا تجعلك مجهول الهوية، ويستطيع مشغّل '
      'خادم عام مجاني مراقبة ما يخرج منه.',
  'privacyNoticeAccept': 'فهمت، تابع.',

  // ——— قصة الاتصال ———
  //
  // تُصدرها طبقة الاتصال، وهي بلا أي واجهة حولها: يُحلّلها المتحكم بلغة
  // المستخدم ويسلّم الشاشة جملة مكتملة. رموز القوالب ({seconds}، {ip}…)
  // تُستبدل عند الإصدار بالقيم المقيسة لهذه المحاولة.
  'flowNotConnected': 'غير متصل.',
  'flowNegotiating': 'جارٍ التفاوض مع الخادم…',
  'flowInterfaceUp': 'واجهة النفق جاهزة؛ في انتظار اكتمال الخادم للاتصال…',
  'flowNetworkChanged': 'تغيّرت الشبكة؛ جارٍ إعادة الاتصال…',
  'flowDisconnecting': 'جارٍ قطع الاتصال…',
  'flowPreparing': 'جارٍ تحضير النفق…',
  'flowPermissionWaiting': 'في انتظار إذن VPN من نظام التشغيل…',
  'flowPermissionNeeded': 'يلزم إذن VPN قبل الاتصال.',
  'flowPermissionDeniedCard':
      'لم يمنح نظام التشغيل إذن VPN، لذا لم يبدأ أي نفق.',
  'flowTunnelFailed': 'فشل النفق.',
  'flowTunnelDied':
      'توقف النفق فجأة قبل أن يكتمل الاتصال. لم يُبلَّغ عن أي خطأ؛ '
      'أول ما يُجرَّب هو إعادة الاتصال بالخادم نفسه.',
  'flowTunnelCancelled': 'أُلغيت محاولة الاتصال.',
  'flowStillShuttingDown':
      'تعذّر بدء الاتصال لأن النفق السابق ما يزال في مرحلة الإيقاف.',
  'flowRetry': 'جارٍ إعادة المحاولة…',
  'flowLookingForServer': 'جارٍ البحث عن خادم…',
  'flowHandshaked': 'اكتملت المصافحة. جارٍ التحقق من عنوان الخروج…',
  'flowConnectedVia':
      'تم الاتصال عبر {ip}، وهو عنوان يختلف عن العنوان المستخدم قبل '
      'الاتصال.',
  'flowBaselineUnavailable':
      'نجحت المصافحة، لكن تعذّر قراءة العنوان المستخدم قبل الاتصال. '
      'لا يمكن تأكيد تغيّر العنوان، لذا لم يُتحقق من الاتصال.',
  'flowAddressFamilyChanged':
      'أعادت خدمات العناوين عائلتَي IP مختلفتين قبل الاتصال وبعده. '
      'هذا لا يثبت مرور البيانات عبر النفق، لذا لم يُتحقق من الاتصال.',
  'flowHandshakeFuture':
      'أبلغ المحرك عن وقت مصافحة في المستقبل. تحقق من ساعة الجهاز؛ '
      'لا يمكن التحقق من الاتصال بهذا الوقت.',
  'flowHandshakeMissing':
      'واجهة النفق جاهزة، لكن الخادم لم يُكمل مصافحة {protocol} بعد، '
      'فلا شيء يُنقَل عبرها. هذا يعني غالبًا أن الخادم تعذر الوصول إليه '
      'أو أنه يرفض هذه الإعدادات.',
  'flowHandshakeStale':
      'كانت آخر مصافحة ناجحة قبل {minutes} دقيقة. توقف الخادم عن '
      'الاستجابة، لذا لم يعد هذا نفقًا عاملًا حتى لو بدت الواجهة قائمة.',
  'flowVerifiedSplitInclude':
      'النفق يعمل. التطبيقات التي اخترتها فقط تستخدمه، لذلك لا يتغير عنوان هذا التطبيق.',
  'flowVerifyCancelled': 'أُلغي التحقق قبل تأكيد عنوان الخروج.',
  'flowVerifyUnreachable':
      'نجحت المصافحة، لكن تعذّر الوصول إلى أي خدمة عناوين خارجية حتى بعد '
      'عدة محاولات، فلم يمكن التحقق من الاتصال. لا يُعرض بأنه متصل لأن '
      'ذلك لم يُثبت.',
  'flowExitUnchanged':
      'لم يتغير العنوان العام بعد الاتصال ({ip} قبله وبعده، مع إعادة '
      'الفحص على مدى عدة ثوانٍ)، لذا ما تزال البيانات تخرج من خارج النفق.',
  'flowTimeout':
      'لم يكتمل الاتصال خلال {seconds} ثانية: {detail}. تم إيقاف النفق.',
  'flowTimeoutNoHandshake': 'لم يبلّغ المحرك عن أي مصافحة',
  'flowTimeoutUnverified': 'تعذّر التحقق من المصافحة في الوقت المناسب',
  'flowStopUnconfirmed':
      'لم يؤكد النظام إيقاف النفق السابق. افصل الاتصال مجددًا قبل بدء '
      'اتصال آخر.',
  'flowLaunchTimeout': 'لم يُكمل النظام تشغيل النفق في الوقت المحدد.',

  // التجول بين الخوادم، بصياغة ما يستطيع المستخدم فعله: ماذا جُرِّب، وفي أي
  // دولة، وهل رُدّ من الخوادم صوت أصلًا.
  'walkNextServer':
      'لم يرد الخادم المختار؛ جارٍ تجربة الخادم التالي ({tried} من '
      '{depth})…',
  'walkSecondTry':
      'أكمل أحد الخوادم المصافحة لكن تعذر تأكيد الخروج. جارٍ تجربة '
      'الخادم نفسه مرة أخرى…',
  'walkExhaustedRetried':
      'جرّبنا {tried} من الخوادم{where}. أكمل أحدها المصافحة، لكن تعذر '
      'تأكيد خروجه حتى في المحاولة الثانية. الخوادم التطوعية كثيرًا ما '
      'تقبل الاتصال في محاولة لاحقة — أعد المحاولة بعد قليل، أو حدّث '
      'القائمة واختر خادمًا آخر.',
  'walkExhaustedSilent':
      'جرّبنا {tried} من الخوادم{where} ولم يكمل أي منها المصافحة. '
      'قوائم الخوادم العامة تتغير سريعًا — حدّث قائمة الخوادم وأعد '
      'المحاولة.',
  'walkExhaustedDark':
      'جرّبنا {tried} من الخوادم{where} ولم يكمل أي منها المصافحة؛ '
      'و{silent} منها لم يرد إطلاقًا. الخوادم التي تبقى صامتة غالبًا '
      'محجوبة أو معطلة — حدّث قائمة الخوادم أو جرّب دولة أخرى.',

  // مشكلات الاختيار والإعدادات: لماذا لم تُجرَ أي محاولة.
  'selNoEndpoints':
      'لا توجد نقاط خوادم متاحة بعد. يمكن للتطبيق تجربة الخوادم المخزنة '
      'إن وُجدت.',
  'selUnknownCountry': 'لا تحتوي قائمة الخوادم على خوادم في {country}.',
  'selAllProtocols':
      'كل الخوادم{where} على بروتوكول {names}، ولا يستطيع هذا الإصدار '
      'بدء الاتصال بها على هذا الجهاز، لذا لم تُجرَ أي محاولة. {remedy}',
  'selThisServer':
      'هذا الخادم على بروتوكول {protocol}، ولا يستطيع هذا الإصدار بدء '
      'الاتصال به على هذا الجهاز، لذا لم تُجرَ أي محاولة. {remedy}',
  'selRemedyWireGuard': 'هذا الإصدار لا يشغّل WireGuard',
  'selRemedyOpenVpn': 'OpenVPN يحتاج إصدارًا يضم محرك المجتمع',
  'selNoEligible':
      'لا يوجد أي خادم يجتاز فحوصات السلامة والثقة حاليًا. أعد المحاولة '
      'بعد قليل.',
  'selNoEligibleCountry':
      'لا يوجد أي خادم في {country} يجتاز فحوصات السلامة والثقة حاليًا.',
  'selCountryOfflineNote':
      'لا يوجد أي خادم في {country} يجتاز فحوصات السلامة والثقة حاليًا؛ '
      'ستُجرَّب خوادمه على أي حال.',
  'selSourceGone':
      'المصدر «{provider}» الذي نشر {host} لم يعد مفعلًا. حدّث قائمة '
      'الخوادم.',
  'selDownloadFailed': 'تعذّر تنزيل إعدادات {host}.',
  'selProfileMissing':
      '{provider} يذكر {host} لكن ملف إعداداته مفقود أو فشل في التحقق، '
      'لذا لا يمكن الاتصال به.',
  'selProtocolOnly':
      '{provider} يذكر {host} لكنه يوفر إعدادات {protocol} فقط، ولا '
      'يستطيع هذا الإصدار بدء الاتصال بها على هذا الجهاز، لذا لا يمكن '
      'الاتصال به.',
  'selNoneSelected': 'لم يُختر أي خادم بعد. اختر خادمًا من «المواقع».',
  'selRetryNeedsSelection':
      'المحاولة الأخيرة لم تصل إلى أي نفق، ولا يوجد اختيار خادم لإعادته. '
      'اختر خادمًا من «المواقع» وأعد المحاولة.',
  'selProfileFallbackNote':
      'لا يوجد ملف إعدادات صالح لأفضل خادم في الترتيب؛ يُستخدم الخادم '
      'المتوافق التالي.',
  'selCachedDirectoryNote':
      'بث الخوادم الحي غير متاح؛ يُجرَّب خادم محفوظ من قبل. لم يتم '
      'التحقق من إمكانية الوصول إليه الآن. {note}',
  'selNextInRankNote': 'الخادم التالي في الترتيب.',

  // أسماء الحالات القصيرة، للأماكن التي لا تحمل فيها الحالة إلا اسمها —
  // سطر الحالة الصغير في العمود الجانبي بعد فشل لا يحمل جملته الخاصة.
  'state.disconnected': 'غير متصل',
  'state.permissionRequired': 'يلزم الإذن',
  'state.preparing': 'جارٍ التحضير',
  'state.connecting': 'جارٍ الاتصال',
  'state.reconnecting': 'جارٍ إعادة الاتصال',
  'state.connected': 'متصل',
  'state.disconnecting': 'جارٍ قطع الاتصال',
  'state.error': 'خطأ',
  'state.blocked': 'يحتاج انتباهك',
  'state.noServerAvailable': 'لا يوجد خادم متاح',

  // أسطر حالة العمود الجانبي، تحت سطور تدفق الاتصال أعلاه.
  'sidebarTunnelEstablished': 'تم إنشاء النفق',
  'sidebarNegotiating': 'جارٍ التفاوض على نفق',
  'sidebarTapToTryAgain': 'اضغط للمحاولة مجددًا',
  'sidebarNeedsAttention': 'يحتاج انتباهك',
  'sidebarNotProtected': 'غير محمي',
  'chooseALocation': 'اختر موقعًا',

  // نصوص كانت مضمنة داخل المكوّنات: كلمات الكرة لكل حالة، أسماء التبويبات،
  // صفوف التشخيص ولوحة الجلسة.
  'servers': 'الخوادم',
  'back': 'رجوع',
  'cancel': 'إلغاء',
  'orbTapToConnect': 'اضغط للاتصال',
  'orbTapToCancel': 'اضغط للإلغاء',
  'orbTapForDetails': 'اضغط للتفاصيل',
  'orbReviewAction': 'مراجعة',
  'orbNotConnected': 'غير متصل',
  'orbSemanticConnect': 'غير متصل. فعِّل للاتصال بالـVPN.',
  'orbSemanticCancel': 'جارٍ الاتصال. فعِّل لإلغاء محاولة الاتصال.',
  'orbSemanticDisconnect': 'متصل. النفق قائم ومرورك يمر من داخله.',
  'orbSemanticRetry': 'غير متصل. فعِّل لإعادة المحاولة.',
  'orbSemanticReview': 'يحتاج انتباهك قبل أن يتمكن من الاتصال.',
  'orbHintConnect': 'اضغط مرتين للاتصال بالـVPN',
  'orbHintCancel': 'اضغط مرتين لإلغاء محاولة الاتصال',
  'orbHintDisconnect': 'اضغط مرتين لقطع الاتصال بالـVPN',
  'orbHintRetry': 'اضغط مرتين لإعادة المحاولة',
  'orbHintReview': 'اضغط مرتين لمعرفة المطلوب',
  'sessionTitle': 'هذه الجلسة',
  'sessionConnectedFor': 'متصل منذ',
  'sessionSession': 'الجلسة',
  'sessionDownloaded': 'تم التنزيل',
  'sessionUploaded': 'تم الرفع',
  'sessionNotVerified': 'غير موثق',
  'sessionIpv6Blocked': 'محجوب',
  'sessionIpv6Allowed': 'مسموح',
  'sessionIpv6ThroughTunnel': 'عبر النفق',
  'diagPublicIp': 'العنوان العام',
  'diagVpnAssignedIp': 'عنوان الـVPN',
  'diagIpv4': 'IPv4',
  'diagIpv6': 'IPv6',
  'diagDns': 'DNS',
  'diagTunnel': 'النفق',
  'diagKillSwitch': 'مفتاح الإيقاف',
  'diagCouldNotMeasure': 'تعذر قياسه',
  'diagIpExternalDetail': 'تُبلِغ بهذا العنوان خدمة خارجية، وهو العنوان الذي تظهر حركتك قادماً منه.',
  'diagIpDirectDetail':
      'لست متصلاً، لذا هذا هو العنوان الذي يستخدمه هذا الجهاز مباشرة.',
  'diagVpnNotVerifiedValue': 'لا يوثق إلا بعد اتصال',
  'diagVpnVerifiedValue': 'العنوان الذي أفاد به تحقق الجلسة كمخرج.',
  'diagVpnNotVerifiedDetail': 'يُقرأ من التحقق نفسه الذي يؤكد الاتصال، لذا يظهر هنا بمجرد التحقق من الجلسة.',
  'diagVpnVerifiedDetail': 'ما أفاد به تحقق الجلسة كعنوان للمخرج.',
  'diagIpv4NotVerifiedDetail': 'يؤكده الدليل نفسه في السطر الأعلى: تغير العنوان العام وبقاؤه متغيراً ما دام النفق قائماً.',
  'diagIpv4VerifiedDetail': 'يمر IPv4 عبر النفق.',
  'diagIpv6BlockedValue': 'محجوب أثناء الاتصال',
  'diagIpv6BlockedDetail': 'واجهة النفق لا تحمل عنوان IPv6، فلا طريق أمام IPv6 للهرب. هذا يخفي العنوان عن المواقع التي تزورها ولا يجعل الاتصال مجهولاً.',
  'diagIpv6NotSupportedDetail': 'لا تستطيع هذه المنصة حجب IPv6، فقد تبقى IPv4 محمية بينما IPv6 ليست كذلك.',
  'diagDnsDetail': 'الملف الذي يرسله الخادم هو من يحدد المُحلِّل، ولا تستطيع هذه الشاشة قراءة المُحلِّل الذي يستخدمه Windows فعلياً، لذا تُبلِغ بذلك بدل أن تدّعي واحداً.',
  'diagTunnelVerifiedDetail': 'تم التحقق من النفق بعد قيامه.',
  'diagTunnelNoTunnelDetail': 'لا نفق قائماً، فلا شيء للتحقق منه.',
  'diagKillSwitchOffDetail':
      'مفتاح الإيقاف معطّل. إذا سقط النفق تخرج الحركة عبر الاتصال العادي. '
      'اختر تلقائي أو صارم في الإعدادات لتحجبها قواعد جدار الحماية.',
  'diagKillSwitchAutomaticDetail':
      'من لحظة الاتصال حتى تضغط قطع الاتصال، تحجب قواعد جدار الحماية حركة '
      'الإنترنت خارج VPN. إذا سقط النفق تبقى القواعد حتى تعيد الاتصال أو '
      'تلغي الحجب. يبقى مسموحًا لـ Phantrix ومحرك VPN وموجّه تقسيم النفق '
      'واستعلامات DNS والشبكة المحلية وDHCP.',
  'diagKillSwitchStrictDetail':
      'تحجب قواعد جدار الحماية حركة الإنترنت خارج VPN كلما لم يكن هناك نفق — '
      'حتى بعد قطع الاتصال وبعد إغلاق Phantrix وبعد إعادة التشغيل. يبقى '
      'مسموحًا لاستعلامات DNS وPhantrix ومحرك VPN وموجّه تقسيم النفق '
      'والشبكة المحلية وDHCP.',
  'diagKillSwitchInactiveValue': 'غير مثبّت',
  'diagKillSwitchInactiveDetail':
      'الوضع المختار لم يثبّت أي قواعد جدار حماية، لذا لا تُحجب الحركة. اتصل، '
      'أو اختر الوضع مرة أخرى، لتثبيت القواعد.',
  'diagKillSwitchNotSupportedDetail': 'لا تضمن هذه المنصة مفتاح إيقاف صارماً. عندما يسقط النفق تخرج الحركة عبر الاتصال العادي حتى يعاد بناؤه، ويُبلِغ Phantrix بذلك بدل أن يدّعي حماية لا يملكها.',
};
