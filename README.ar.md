# Phantrix

[![verify](https://github.com/LaymonGames/phantrix-vpn/actions/workflows/verify.yml/badge.svg?branch=main)](https://github.com/LaymonGames/phantrix-vpn/actions/workflows/verify.yml)
[![windows](https://github.com/LaymonGames/phantrix-vpn/actions/workflows/windows.yml/badge.svg?branch=main)](https://github.com/LaymonGames/phantrix-vpn/actions/workflows/windows.yml)
[![linux](https://github.com/LaymonGames/phantrix-vpn/actions/workflows/linux.yml/badge.svg?branch=main)](https://github.com/LaymonGames/phantrix-vpn/actions/workflows/linux.yml)
[![android](https://github.com/LaymonGames/phantrix-vpn/actions/workflows/android.yml/badge.svg?branch=main)](https://github.com/LaymonGames/phantrix-vpn/actions/workflows/android.yml)
[![license: GPL-3.0-only](https://img.shields.io/badge/license-GPL--3.0--only-blue.svg)](LICENSE)
[![PRs welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](#المساهمة)

**العربية** · [English](README.md)

<div dir="rtl">

Phantrix عميل VPN مجاني لـ OpenVPN، مكتوب بـ Flutter، ولا يتطلب حسابًا. لا تسجيل، لا اشتراك، ولا تحليلات. هو عميل فقط: لا يضمّ خوادم، وقائمة المرحّلات تأتي من VPN Gate، وهي شبكة مرحّلات عامة يديرها متطوّعون.

شيفرة Phantrix مرخّصة تحت **GPL-3.0-only** (انظر [الترخيص](#الترخيص)).

> **الحالة: مبكّر، ومعظم أجزائه غير مُتحقَّق منها.** شوهد نفق OpenVPN حيّ يعمل على ويندوز في أكتوبر 2026. اقرأ [حالة المنصات](#حالة-المنصات) قبل الاعتماد عليه.

## الميزات

- **لا حاجة للتسجيل.** بلا حساب، بلا اشتراك، وبلا مكتبة تحليلات.
- **OpenVPN عبر المحرّك الرسمي.** Phantrix لا ينفّذ تعمية VPN بنفسه؛ وعلى ويندوز يعمل المحرّك داخل عملية مساعدة منفصلة بصلاحية مسؤول.
- **مرحّلات عامة من VPN Gate.** تُجلب قائمة الخوادم من VPN Gate أثناء التشغيل وتُحفظ مؤقتًا؛ وPhantrix لا يملك خوادم خاصة.
- **حالة صادقة.** لا يظهر "متصل" إلا بعد أن يُكمل المحرّك المصافحة وتغيّر عنوانك العام؛ وأي شيء آخر يُذكر صراحة.
- **الإنجليزية والعربية**، مع دعم التخطيط من اليمين إلى اليسار.

## لقطات الشاشة

الحالات الخمس لزر الاتصال:

![غير متصل، جارٍ الاتصال، متصل، لا اتصال، يحتاج انتباهًا](docs/evidence/ui/09-control-states.png)

التطبيق على سطح المكتب، والإعدادات مع اختيار اللغة:

![الواجهة الرئيسية](docs/evidence/ui/03-dashboard-desktop.png)

![الإعدادات](docs/evidence/ui/06-settings-desktop.png)

هذه اللقطات يُنتجها اختبار الواجهة (`test/ui_screenshots_test.dart`) وليست من نفق حيّ.

---

## البدء السريع (البناء من المصدر)

هذه الخطوات خاصة بـ **ويندوز**، المنصة الوحيدة التي تتيح الاتصال بمرحّلات VPN Gate. لبقية المنصات راجع [BUILDING.md](BUILDING.md).

**تحتاج:** Flutter (3.47.0 أو أحدث)، وVisual Studio 2022 مع حزمة عمل "Desktop development with C++".

من جذر المستودع، في طرفية ويندوز عادية:

```powershell
flutter pub get

# Downloads the OpenVPN engine and the wintun driver, and verifies their
# pinned SHA-256 hashes. Required for OpenVPN and the VPN Gate relays.
powershell -NoProfile -ExecutionPolicy Bypass -File tools\fetch_openvpn_bundle.ps1

flutter run -d windows            # or: flutter build windows --release
```

ملاحظات:

- **لا تتخطَّ خطوة التنزيل.** فمحرّك OpenVPN مقصود أن يبقى خارج git (كل ما تحت `packages/phantrix_platform/windows/bundle/` متجاهل). نسخة بدون تنزيل تُبنى، لكن التطبيق يُبلّغ أن OpenVPN غير متاح ويرفض كل مرحّل مع توضيح.
- إذا بنيت قبل التنزيل، نفّذ `flutter clean` ثم أعد البناء ليلتقط CMake الملفات الجديدة.
- لإعادة فحص الملفات المنزّلة دون تنزيل، أضف `-VerifyOnly` إلى الأمر.
- يستخدم الأمر PowerShell المرفق مع ويندوز؛ لا حاجة لـ PowerShell 7 (`pwsh`).
- اتصالات OpenVPN تطلب موافقة المسؤول (نافذة UAC) لأن المحرّك يعمل داخل مساعد منفصل بصلاحية مسؤول؛ أما التطبيق فليس كذلك.

## الاستخدام

- **OpenVPN** هو البروتوكول الوحيد، وعلى ويندوز فقط. اختر مرحّلًا من قائمة VPN Gate. ويُتحقَّق من الملف التعريفي قبل أن يراه المحرّك.
- **VPN Gate هو المصدر الوحيد للخوادم.** لا يوجد استيراد للملفات التعريفية بعد، لذا يستخدم كل اتصال مرحّلًا من تلك القائمة.
- تُعرض الخوادم مع بلدانها، و**اختر موقعًا** يحفظ اختيارك. وعندما يختار تلقائيًا، يجرّب التطبيق أعلى المرحّلات ترتيبًا واحدًا بعد الآخر، ويُخبرك بالموقع الذي استقرّ عليه.

لا يقول Phantrix "متصل" إلا بعد أن يؤكد المحرّك إتمام المصافحة وتغيّر عنوانك العام. وإلا وضّح سبب عدم الاتصال بدل علامة خضراء.

---

## حالة المنصات

| المنصة | المحرّك الذي يستطيع التطبيق استخدامه | ما تمّ التحقق منه |
| --- | --- | --- |
| ويندوز | ملفات OpenVPN 2.6 الرسمية + wintun، تعمل كعملية مساعدة منفصلة | OpenVPN: شوهدت أنفاق حيّة؛ وجلسة استمرّت 6.5 دقائق في 2026-10-11 تأكّدت بتغيّر عنوان الخروج (`docs/evidence/openvpn/`) |
| أندرويد | لا شيء. لا محرّك على أندرويد — OpenVPN لا يمكن شحنه هناك، وأُزيلت خلفية WireGuard — لذا يرفض التطبيق كل مرحّل مع توضيح | سُجِّل أن اختبارات التطبيق تمر على محاكي أندرويد 14، قبل أن يصبح التطبيق مقتصرًا على OpenVPN |
| لينكس | لا شيء | يُبنى في CI. ولم يُشغَّل قط على نظام حيّ |
| macOS / iOS | لا شيء | شيفرة Apple موجودة في `packages/phantrix_platform/apple/` لكنها لم تُصرَّف قط وليست هدف بناء |
| الويب | لا شيء | المتصفح لا يستطيع تمرير حركة النظام. التطبيق يُبنى، وفشل "اتصال" فيه واضح ومقصود |

"المحرّك الرسمي" يعني أن Phantrix يستخدم محرّك المنبع ولا ينفّذ أي تعمية VPN بنفسه. وهو لا يقول شيئًا عن عمل النفق على منصة معيّنة.

مرحّلات VPN Gate العامة تنشر ملفات تعريف OpenVPN فقط، لذا تُعرض على المنصات التي لا تملك محرّك OpenVPN، لكن لا يمكن الاتصال بها. والمرحّلات يديرها متطوّعون وقد لا تكون متاحة من شبكتك.

إصدارات أندرويد التنزيلية **موقّعة بمفتاح تصحيح** ما لم تقدّم مفتاح رفع خاصًا بك؛ انظر [BUILDING.md](BUILDING.md).

## ما تفعله VPN وما لا تفعله

VPN يخفي حركتك عن الشبكة المحلية وعن مزوّد خدمة الإنترنت، ويُظهر للمواقع عنوان الخادم بدلًا من عنوانك. لكنه **لا** يجعلك مجهول الهوية: فمشغّل خادم الخروج يرى الحركة الخارجة منه، وفي المرحّلات العامة يكون ذلك المشغّل متطوّعًا مجهولًا. كذلك لا يحمي حساباتك ولا جهازك ولا يحميك من التتبّع على مستوى التطبيقات.

لا تنفّذ أيّ من الخلفيات مفتاحَ إيقافٍ صارمًا يحجب الحركة. وإعداد IPv6 تفضيل، وليس دليلًا على حجب على مستوى المضيف — فعلى ويندوز يُبلّغ التطبيق أنه لا يستطيع حجب IPv6 على مستوى المضيف. وتغيّر عنوان IPv4 لا يثبت حماية من تسريب DNS أو IPv6؛ وهذه تبقى غير مُتحقَّق منها.

## الخصوصية

لا حساب، ولا مكتبة تحليلات، ولا مُبلِّغ أعطال. يجلب التطبيق قائمة خوادم VPN Gate ويتحقق من عنوانك العام (عبر ipify وخدمة `checkip` من أمازون) للتأكد من النفق. راجع [PRIVACY.md](PRIVACY.md) لمعرفة ما يُخزَّن بالضبط وكيف تحذفه.

---

## التطوير

```bash
flutter pub get
flutter analyze
flutter test

cd packages/phantrix_core && dart pub get && dart test
```

بعد أي تغيير في التبعيات، أعد توليد قائمة التراخيص داخل التطبيق وأضف الناتج إلى الالتزام:

```bash
dart run tools/generate_third_party_notices.dart
```

ويعيد `--check` بناء القائمة نفسها ويقارنها بالملف الملتزَم دون كتابة، ويفشل إذا اختلفتا. وهذه هي الصيغة التي تشغّلها CI، فيُكشف تغيير التبعيات الذي نُسي إعادة توليد قائمته بدل أن تُبقي شاشة التراخيص إصدارات لا يُبنَى بها.

```bash
dart run tools/generate_third_party_notices.dart --check
```

البنية: `lib/` (واجهة Flutter)، و`packages/phantrix_core/` (تحليل البروتوكولات والتحقق والاكتشاف وآلة الحالة)، و`packages/phantrix_platform/` (شيفرة النفق الأصلية لكل منصة). انظر [ARCHITECTURE.md](ARCHITECTURE.md).

## الوثائق

| الملف | يغطّي |
| --- | --- |
| [BUILDING.md](BUILDING.md) | سلاسل الأدوات وخطوات البناء لكل منصة |
| [ARCHITECTURE.md](ARCHITECTURE.md) | تنظيم الحزم وجسر المنصات |
| [SECURITY.md](SECURITY.md) | نموذج التهديد وقواعد التحقق والإبلاغ عن ثغرة |
| [PRIVACY.md](PRIVACY.md) | ما يُخزَّن وما لا يُجمَع |
| [CONTRIBUTING.md](CONTRIBUTING.md) | سير العمل وقائمة فحص طلبات الدمج |
| [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md) | التبعيات والمكوّنات المضمّنة مع تراخيصها |
| [docs/LICENSING_AUDIT.md](docs/LICENSING_AUDIT.md) | مراجعة التوافق مع GPL-3.0 |
| [docs/EVIDENCE.md](docs/EVIDENCE.md) | ما تمّ التحقق منه، وكيف، وما بقي مفتوحًا |

## المساهمة

المساهمات مرحّب بها — أرسل طلب دمج. واقرأ [CONTRIBUTING.md](CONTRIBUTING.md) أولًا: إنه قصير، وقاعدته الصارمة الوحيدة هي الصدق الذي يحاول هذا README الالتزام به — لا يُوصف شيء بأنه يعمل قبل أن يُشاهَد يعمل.

ومن الطرق الصغيرة المفيدة: شغّله على منصة لم يجرّبها أحد وأخبرنا بما حدث؛ أخبرنا عندما يتوقف مرحّل عن الاستجابة؛ حسّن العربية؛ أو شدّد جملة أعلاه تدّعي أكثر مما تفعله الشيفرة. والبلاغات عن توثيق يبالغ في ادعاءاته تُعامَل كقضايا عادية.

## الترخيص

شيفرة Phantrix الأصلية مرخّصة تحت **GNU General Public License v3.0 only** (`GPL-3.0-only`). انظر [LICENSE](LICENSE) لنص الترخيص و[COPYRIGHT](COPYRIGHT) للإشعار. والترخيص يخص الشيفرة المكتوبة باستقلال؛ أما شيفرة الأطراف الثالثة والمقتبسة فتبقى بترخيصها، وهي مسرودة في [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md) وداخل التطبيق تحت **الإعدادات ← حول، التراخيص والاعتمادات**.

- **حزمة ويندوز:** محرّك OpenVPN 2 المجتمعي (GPL-2.0) يعمل كعملية منفصلة غير معدّلة، وهذا تجميع لا عمل مشترك. وبرنامج تشغيل wintun تحت ترخيص WireGuard LLC للثنائيات الجاهزة، ويجب أن يبقى غير معدّل ومقترنًا بـ OpenVPN. لا شيء منهما مضمَّن في هذا المستودع؛ بل يُنزَّلان عبر `tools/fetch_openvpn_bundle.ps1`.
- **بناء ويندوز للإصدار** يثبّت مجلد `licenses/` بجوار `phantrix.exe`، ويضم `LICENSE` و`COPYRIGHT` لهذا المشروع، و`THIRD_PARTY_LICENSES.md` المولَّد، ونصّي OpenVPN وwintun. وكلها ملتزَمة في هذا المستودع، فلا تحتاج القاعدة إلى اتصال بالشبكة. ويعرض التطبيق القائمة ذاتها تحت **الإعدادات ← حول، التراخيص والاعتمادات**.
- **أندرويد:** لا يوجد محرّك OpenVPN، لأن المحرّك الوحيد المتاح (ics-openvpn) بترخيص GPL-2.0-only ولا يمكن دمجه مع شيفرة GPL-3.0. لا تُضِفه، ولا أي شيفرة GPL-2.0-only أخرى، إلى بناء أندرويد.

هذه مراجعة هندسية وليست نصيحة قانونية.

</div>
