part of 'strings.dart';

/// The app's own, translated sentences for the platform error codes that
/// have a fixed, human-readable message.
///
/// The native sides report failure reasons in English. Codes whose message
/// is a *sentence a user acts on* are listed here in both languages, and the
/// connection layer prefers this entry over the native one. Codes whose
/// message carries a file path, a process name or an engine's own words
/// (`ovpn.paths_*`, `ovpn.profile_missing`, `backend.*`, `ovpn.engine_exited`,
/// `ovpn.config_rejected` and friends) are deliberately absent — the native
/// text is the diagnosis, and paraphrasing it would only be faithful in the
/// language it was written in.
const Map<String, Map<String, String>> _problemValues = {
  'en': _problemsEn,
  'ar': _problemsAr,
};

const Map<String, String> _problemsEn = {
  'permission.denied': 'The operating system did not grant VPN permission.',
  'permission.revoked':
      'VPN permission was withdrawn. Phantrix stopped the tunnel.',
  'permission.always_on_conflict':
      'Another VPN is currently active on this device.',
  'ovpn.auth_failed':
      'The server rejected the authentication. Volunteer relays sometimes '
      'reject connections when they are overloaded or blocked.',
  'ovpn.tls_failed': 'The TLS handshake failed.',
  'ovpn.driver_failed':
      'The VPN tunnel driver could not be set up on this computer.',
  'ovpn.driver_not_registered':
      'The VPN adapter was created but could not be registered with the '
      'OpenVPN engine, so the engine would not have found it.',
  'server.unreachable': 'The VPN server could not be reached.',
  'server.overloaded': 'The VPN server is overloaded.',
  'dns.failed': 'The VPN DNS could not be configured.',
  'network.changed': 'The network changed while connecting.',
  'kill_switch.unsupported':
      'This platform cannot enforce a strict kill switch.',
};

const Map<String, String> _problemsAr = {
  'permission.denied': 'لم يمنح نظام التشغيل إذن VPN.',
  'permission.revoked': 'سُحب إذن VPN، وأوقف فيلجيت النفق.',
  'permission.always_on_conflict':
      'تعمل شبكة افتراضية أخرى على هذا الجهاز حاليًا.',
  'ovpn.auth_failed':
      'رفض الخادم المصادقة. الخوادم التطوعية ترفض الاتصال أحيانًا '
      'عند ازدحامها أو حجبها.',
  'ovpn.tls_failed': 'فشلت مصافحة TLS.',
  'ovpn.driver_failed': 'تعذّر تجهيز مشغّل النفق على هذا الحاسوب.',
  'ovpn.driver_not_registered':
      'أُنشئ محوّل الشبكة للنفق لكن تعذّر تسجيله لدى محرك OpenVPN، '
      'لذا لم يكن المحرك ليجده.',
  'server.unreachable': 'تعذّر الوصول إلى خادم VPN.',
  'server.overloaded': 'خادم VPN مكتظ بالطلبات.',
  'dns.failed': 'تعذّر إعداد DNS لشبكة VPN.',
  'network.changed': 'تغيّرت الشبكة أثناء الاتصال.',
  'kill_switch.unsupported': 'لا تستطيع هذه المنصة فرض مفتاح إيقاف صارم.',
};
