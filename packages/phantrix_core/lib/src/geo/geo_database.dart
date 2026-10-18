import 'dart:math' as math;

/// A country entry used by the location browser.
class GeoCountry {
  const GeoCountry({
    required this.iso2,
    required this.iso3,
    required this.nameEn,
    required this.nameAr,
    required this.continent,
    required this.latitude,
    required this.longitude,
  });

  final String iso2;
  final String iso3;
  final String nameEn;
  final String nameAr;
  final String continent;
  final double latitude;
  final double longitude;

  /// Flag as a regional-indicator emoji pair.
  String get flag => String.fromCharCodes(
    iso2.toUpperCase().codeUnits.map((c) => c + 0x1F1E6 - 0x41),
  );

  String nameFor(String languageCode) =>
      languageCode.toLowerCase().startsWith('ar') ? nameAr : nameEn;

  /// Great-circle distance in kilometres.
  double distanceKm(double lat, double lon) {
    const earthRadius = 6371.0;
    final dLat = _rad(lat - latitude);
    final dLon = _rad(lon - longitude);
    final a =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_rad(latitude)) *
            math.cos(_rad(lat)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    return earthRadius * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  static double _rad(double deg) => deg * math.pi / 180;

  @override
  String toString() => nameEn;
}

/// Offline ISO 3166-1 reference data.
///
/// Embedded as source so the location browser, the map and the server lists
/// work with no network at all. Server availability always comes from the
/// live directory: this table only maps a code to a name, a flag and a
/// position, and never implies that a server exists there.
class GeoDatabase {
  GeoDatabase._();

  static final Map<String, GeoCountry> _byIso2 = _load();

  static final Map<String, GeoCountry> _byIso3 = {
    for (final entry in _byIso2.values) entry.iso3: entry,
  };

  static GeoCountry? byIso2(String code) => _byIso2[code.toUpperCase()];

  static GeoCountry? byIso3(String code) => _byIso3[code.toUpperCase()];

  static String nameOf(String code, [String languageCode = 'en']) {
    final country = byIso2(code) ?? byIso3(code);
    return country?.nameFor(languageCode) ?? code;
  }

  static String flagOf(String code) =>
      (byIso2(code) ?? byIso3(code))?.flag ?? '🌐';

  static List<GeoCountry> get all => List.unmodifiable(
    _byIso2.values.toList()..sort((a, b) => a.nameEn.compareTo(b.nameEn)),
  );

  static int get countryCount => _byIso2.length;

  static String continentLabel(String code) => switch (code) {
    'AF' => 'Africa',
    'AS' => 'Asia',
    'EU' => 'Europe',
    'NA' => 'North America',
    'SA' => 'South America',
    'OC' => 'Oceania',
    'AN' => 'Antarctica',
    _ => code,
  };

  static Map<String, GeoCountry> _load() {
    final map = <String, GeoCountry>{};
    for (final line in _rows.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        continue;
      }
      final parts = trimmed.split(' ');
      if (parts.length < 7) {
        continue;
      }
      // English and Arabic names may both contain multiple words. Find the
      // first Arabic-script token rather than assuming the Arabic name is a
      // single token (which truncated names such as "United Arab Emirates").
      final nameTokens = parts.sublist(2, parts.length - 3);
      final arabicStart = nameTokens.indexWhere(_arabicScript.hasMatch);
      final nameEn = arabicStart > 0
          ? nameTokens.take(arabicStart).join(' ')
          : nameTokens.join(' ');
      final nameAr = arabicStart >= 0
          ? nameTokens.skip(arabicStart).join(' ')
          : nameEn;
      final country = GeoCountry(
        iso2: parts[0].toUpperCase(),
        iso3: parts[1].toUpperCase(),
        nameEn: nameEn,
        nameAr: nameAr,
        continent: parts[parts.length - 3],
        latitude: double.parse(parts[parts.length - 2]),
        longitude: double.parse(parts[parts.length - 1]),
      );
      map[country.iso2] = country;
    }
    return map;
  }

  static final RegExp _arabicScript = RegExp(r'[\u0600-\u06FF]');

  static const String _rows = '''
AD AND Andorra أندورا EU 42.5462 1.6016
AE ARE United Arab Emirates الإمارات العربية المتحدة AS 23.4241 53.8478
AF AFG Afghanistan أفغانستان AS 33.9391 67.7100
AG ATG Antigua and Barbuda أنتيغوا وباربودا NA 17.0608 -61.7964
AI AIA Anguilla أنغويلا NA 18.2500 -63.1667
AL ALB Albania ألبانيا EU 41.1533 20.1683
AM ARM Armenia أرمينيا AS 40.0691 45.0382
AO AGO Angola أنغولا AF -11.2027 17.8739
AQ ATA Antarctica أنتاركتيكا AN -82.8600 135.0000
AR ARG Argentina الأرجنتين SA -38.4161 -63.6167
AS ASM American Samoa ساموا الأمريكية OC -14.3333 -170.0000
AT AUT Austria النمسا EU 47.5162 14.5501
AU AUS Australia أستراليا OC -25.2744 133.7751
AW ABW Aruba أروبا NA 12.5000 -69.9667
AX ALA Åland Islands جزر آلاند EU 60.1800 19.9200
AZ AZE Azerbaijan أذربيجان AS 40.1431 47.5769
BA BIH Bosnia and Herzegovina البوسنة والهرسك EU 43.9159 17.6791
BB BRB Barbados بربادوس NA 13.1939 -59.5432
BD BGD Bangladesh بنغلاديش AS 23.6850 90.3563
BE BEL Belgium بلجيكا EU 50.5039 4.4699
BF BFA Burkina Faso بوركينا فاسو AF 12.2383 -1.5616
BG BGR Bulgaria بلغاريا EU 42.7339 25.4858
BH BHR Bahrain البحرين AS 26.0667 50.5577
BI BDI Burundi بوروندي AF -3.3731 29.9189
BJ BEN Benin بنين AF 9.3077 2.3158
BL BLM Saint Barthélemy سان بارتليمي NA 17.9000 -62.8300
BM BMU Bermuda برمودا NA 32.3333 -64.7500
BN BRN Brunei بروناي AS 4.5353 114.7277
BO BOL Bolivia بوليفيا SA -16.2902 -63.5887
BQ BES Bonaire, Sint Eustatius and Saba هولندا الكاريبية NA 12.1800 -68.2500
BR BRA Brazil البرازيل SA -14.2350 -51.9253
BS BHS Bahamas الباهاما NA 25.0343 -77.3963
BT BTN Bhutan بوتان AS 27.5142 90.4336
BV BVT Bouvet Island جزيرة بوفيه AN -54.4200 3.3800
BW BWA Botswana بوتسوانا AF -22.3285 24.6849
BY BLR Belarus بيلاروسيا EU 53.7098 27.9534
BZ BLZ Belize بيليز NA 17.1899 -88.4976
CA CAN Canada كندا NA 56.1304 -106.3468
CC CCK Cocos (Keeling) Islands جزر كوكوس (كيلينغ) OC -12.5000 96.8333
CD COD DR Congo الكونغو الديمقراطية AF -4.0383 21.7587
CF CAF Central African Republic أفريقيا الوسطى AF 6.6111 20.9394
CG COG Congo الكونغو AF -0.2280 15.8277
CH CHE Switzerland سويسرا EU 46.8182 8.2275
CI CIV Ivory Coast ساحل العاج AF 7.5400 -5.5471
CK COK Cook Islands جزر كوك OC -21.2333 -159.7667
CL CHL Chile تشيلي SA -35.6751 -71.5430
CM CMR Cameroon الكاميرون AF 7.3697 12.3547
CN CHN China الصين AS 35.8617 104.1954
CO COL Colombia كولومبيا SA 4.5709 -74.2973
CR CRI Costa Rica كوستاريكا NA 9.7489 -83.7534
CU CUB Cuba كوبا NA 21.5218 -77.7812
CV CPV Cape Verde الرأس الأخضر AF 16.5388 -23.0418
CW CUW Curaçao كوراساو NA 12.1700 -68.9900
CX CXR Christmas Island جزيرة كريسماس OC -10.5000 105.6667
CY CYP Cyprus قبرص EU 35.1264 33.4299
CZ CZE Czechia التشيك EU 49.8175 15.4730
DE DEU Germany ألمانيا EU 51.1657 10.4515
DJ DJI Djibouti جيبوتي AF 11.8251 42.5903
DK DNK Denmark الدنمارك EU 56.2639 9.5018
DM DMA Dominica دومينيكا NA 15.414999 -61.370976
DO DOM Dominican Republic الدومينيكان NA 18.7357 -70.1627
DZ DZA Algeria الجزائر AF 28.0339 1.6596
EC ECU Ecuador الإكوادور SA -1.8312 -78.1834
EE EST Estonia إستونيا EU 58.5953 25.0136
EG EGY Egypt مصر AF 26.8206 30.8025
EH ESH Western Sahara الصحراء الغربية AF 24.5000 -13.0000
ER ERI Eritrea إريتريا AF 15.1794 39.7823
ES ESP Spain إسبانيا EU 40.4637 -3.7492
ET ETH Ethiopia إثيوبيا AF 9.1450 40.4897
FI FIN Finland فنلندا EU 61.9241 25.7482
FJ FJI Fiji فيجي OC -17.7134 178.0650
FK FLK Falkland Islands (Malvinas) جزر فوكلاند SA -51.7500 -59.0000
FM FSM Micronesia, Federated States of ميكرونيزيا OC 6.9167 158.2500
FO FRO Faroe Islands جزر فارو EU 62.0000 -6.7833
FR FRA France فرنسا EU 46.2276 2.2137
GA GAB Gabon الغابون AF -0.8037 11.6094
GB GBR United Kingdom المملكة المتحدة EU 55.3781 -3.4360
GD GRD Grenada غرينادا NA 12.1165 -61.6790
GE GEO Georgia جورجيا AS 42.3154 43.3569
GF GUF French Guiana غويانا الفرنسية SA 4.0000 -53.0000
GG GGY Guernsey غيرنزي EU 49.4667 -2.5833
GH GHA Ghana غانا AF 7.9465 -1.0232
GI GIB Gibraltar جبل طارق EU 36.1377 -5.3453
GL GRL Greenland غرينلاند NA 71.7069 -42.6043
GM GMB Gambia غامبيا AF 13.4432 -15.3101
GN GIN Guinea غينيا AF 9.9456 -9.6966
GP GLP Guadeloupe غوادلوب NA 16.2500 -61.5833
GQ GNQ Equatorial Guinea غينيا الاستوائية AF 1.6508 10.2679
GR GRC Greece اليونان EU 39.0742 21.8243
GS SGS South Georgia and the South Sandwich Islands جورجيا الجنوبية وجزر ساندويتش الجنوبية SA -54.5000 -37.0000
GT GTM Guatemala غواتيمالا NA 15.7835 -90.2308
GU GUM Guam غوام OC 13.4443 144.7937
GW GNB Guinea-Bissau غينيا بيساو AF 11.8037 -15.1804
GY GUY Guyana غيانا SA 4.8604 -58.9302
HK HKG Hong Kong هونغ كونغ AS 22.3964 114.1095
HM HMD Heard Island and McDonald Islands جزيرة هيرد وجزر ماكدونالد AN -53.1000 72.5167
HN HND Honduras هندوراس NA 15.2000 -86.2419
HR HRV Croatia كرواتيا EU 45.1000 15.2000
HT HTI Haiti هايتي NA 18.9712 -72.2852
HU HUN Hungary المجر EU 47.1625 19.5033
ID IDN Indonesia إندونيسيا AS -0.7893 113.9213
IE IRL Ireland أيرلندا EU 53.4129 -8.2439
IL ISR Israel إسرائيل AS 31.0461 34.8516
IM IMN Isle of Man جزيرة مان EU 54.2500 -4.5000
IN IND India الهند AS 20.5937 78.9629
IO IOT British Indian Ocean Territory الإقليم البريطاني في المحيط الهندي AF -6.0000 71.5000
IQ IRQ Iraq العراق AS 33.2232 43.6793
IR IRN Iran إيران AS 32.4279 53.6880
IS ISL Iceland آيسلندا EU 64.9631 -19.0208
IT ITA Italy إيطاليا EU 41.8719 12.5674
JE JEY Jersey جيرسي EU 49.2500 -2.1667
JM JAM Jamaica جامايكا NA 18.1096 -77.2975
JO JOR Jordan الأردن AS 30.5852 36.2384
JP JPN Japan اليابان AS 36.2048 138.2529
KE KEN Kenya كينيا AF -0.0236 37.9062
KG KGZ Kyrgyzstan قيرغيزستان AS 41.2044 74.7661
KH KHM Cambodia كمبوديا AS 12.5657 104.9910
KI KIR Kiribati كيريباتي OC 1.4167 173.0000
KM COM Comoros جزر القمر AF -12.1667 44.2500
KN KNA Saint Kitts and Nevis سانت كيتس ونيفيس NA 17.3333 -62.7500
KP PRK North Korea كوريا الشمالية AS 40.3399 127.5101
KR KOR South Korea كوريا الجنوبية AS 35.9078 127.7669
KW KWT Kuwait الكويت AS 29.3117 47.4818
KY CYM Cayman Islands جزر كايمان NA 19.5000 -80.5000
KZ KAZ Kazakhstan كازاخستان AS 48.0196 66.9237
LA LAO Laos لاوس AS 19.8563 102.4955
LB LBN Lebanon لبنان AS 33.8547 35.8623
LC LCA Saint Lucia سانت لوسيا NA 13.9094 -60.9789
LI LIE Liechtenstein ليختنشتاين EU 47.1660 9.5554
LK LKA Sri Lanka سريلانكا AS 7.0000 81.0000
LR LBR Liberia ليبيريا AF 6.4281 -9.4295
LS LSO Lesotho ليسوتو AF -29.6100 28.2336
LT LTU Lithuania ليتوانيا EU 55.1694 23.8813
LU LUX Luxembourg لوكسمبورغ EU 49.8153 6.1296
LV LVA Latvia لاتفيا EU 56.8796 24.6032
LY LBY Libya ليبيا AF 26.3351 17.2283
MA MAR Morocco المغرب AF 31.7917 -7.0926
MC MCO Monaco موناكو EU 43.7500 7.4167
MD MDA Moldova مولدوفا EU 47.4116 28.3699
ME MNE Montenegro الجبل الأسود EU 42.7087 19.3744
MF MAF Saint Martin (French part) سان مارتن NA 18.0700 -63.0800
MG MDG Madagascar مدغشقر AF -18.7669 46.8691
MH MHL Marshall Islands جزر مارشال OC 7.1315 171.1845
MK MKD North Macedonia مقدونيا الشمالية EU 41.6086 21.7453
ML MLI Mali مالي AF 17.5707 -3.9962
MM MMR Myanmar ميانمار AS 21.9162 95.9560
MN MNG Mongolia منغوليا AS 46.8625 103.8467
MO MAC Macao منطقة ماكاو الإدارية الخاصة AS 22.1667 113.5500
MP MNP Northern Mariana Islands جزر ماريانا الشمالية OC 15.2000 145.7500
MQ MTQ Martinique جزر المارتينيك NA 14.6667 -61.0000
MR MRT Mauritania موريتانيا AF 21.0079 -10.9408
MS MSR Montserrat مونتسرات NA 16.7500 -62.2000
MT MLT Malta مالطا EU 35.9375 14.3754
MU MUS Mauritius موريشيوس AF -20.3484 57.5522
MV MDV Maldives المالديف AS 3.2028 73.2207
MW MWI Malawi مالاوي AF -13.2543 34.3015
MX MEX Mexico المكسيك NA 23.6345 -102.5528
MY MYS Malaysia ماليزيا AS 4.2105 101.9758
MZ MOZ Mozambique موزمبيق AF -18.6657 35.5296
NA NAM Namibia ناميبيا AF -22.9576 18.4904
NC NCL New Caledonia كاليدونيا الجديدة OC -20.9043 165.6181
NE NER Niger النيجر AF 17.6078 8.0817
NF NFK Norfolk Island جزيرة نورفولك OC -29.0333 167.9500
NG NGA Nigeria نيجيريا AF 9.0820 8.6753
NI NIC Nicaragua نيكاراغوا NA 12.8654 -85.2072
NL NLD Netherlands هولندا EU 52.1326 5.2913
NO NOR Norway النرويج EU 60.4720 8.4689
NP NPL Nepal نيبال AS 28.3949 84.1240
NR NRU Nauru ناورو OC -0.5228 166.9315
NU NIU Niue نيوي OC -19.0333 -169.8667
NZ NZL New Zealand نيوزيلندا OC -40.9006 174.8860
OM OMN Oman عمان AS 21.4735 52.4591
PA PAN Panama بنما NA 8.5380 -80.7821
PE PER Peru بيرو SA -9.1900 -75.0152
PF PYF French Polynesia بولينيزيا الفرنسية OC -15.0000 -140.0000
PG PNG Papua New Guinea بابوا غينيا الجديدة OC -6.3150 143.9555
PH PHL Philippines الفلبين AS 12.8797 121.7740
PK PAK Pakistan باكستان AS 30.3753 69.3451
PL POL Poland بولندا EU 51.9194 19.1451
PM SPM Saint Pierre and Miquelon سان بيير ومكويلون NA 46.8333 -56.3333
PN PCN Pitcairn جزر بيتكيرن OC -25.0667 -130.1000
PR PRI Puerto Rico بورتوريكو NA 18.2208 -66.5901
PS PSE Palestine فلسطين AS 31.9522 35.2332
PT PRT Portugal البرتغال EU 39.3999 -8.2245
PW PLW Palau بالاو OC 7.5000 134.5000
PY PRY Paraguay باراغواي SA -23.4425 -58.4438
QA QAT Qatar قطر AS 25.3548 51.1839
RE REU Reunion لا ريونيون AF -21.1151 55.5364
RO ROU Romania رومانيا EU 45.9432 24.9668
RS SRB Serbia صربيا EU 44.0165 21.0059
RU RUS Russia روسيا EU 61.5240 105.3188
RW RWA Rwanda رواندا AF -1.9403 29.8739
SA SAU Saudi Arabia السعودية AS 23.8859 45.0792
SB SLB Solomon Islands جزر سليمان OC -9.6457 160.1562
SC SYC Seychelles سيشل AF -4.6796 55.4920
SD SDN Sudan السودان AF 12.8628 30.2176
SE SWE Sweden السويد EU 60.1282 18.6435
SG SGP Singapore سنغافورة AS 1.3521 103.8198
SH SHN Saint Helena, Ascension and Tristan da Cunha سانت هيلينا AF -15.9500 -5.7000
SI SVN Slovenia سلوفينيا EU 46.1512 14.9955
SJ SJM Svalbard and Jan Mayen سفالبارد وجان ماين EU 78.0000 20.0000
SK SVK Slovakia سلوفاكيا EU 48.6690 19.6990
SL SLE Sierra Leone سيراليون AF 8.4606 -11.7799
SM SMR San Marino سان مارينو EU 43.9424 12.4578
SN SEN Senegal السنغال AF 14.4974 -14.4524
SO SOM Somalia الصومال AF 5.1521 46.1996
SR SUR Suriname سورينام SA 3.9193 -56.0278
SS SSD South Sudan جنوب السودان AF 6.8765 31.3060
ST STP Sao Tome and Principe ساو تومي وبرينسيبي AF 0.1864 6.6131
SV SLV El Salvador السلفادور NA 13.7942 -88.8965
SX SXM Sint Maarten (Dutch part) سانت مارتن NA 18.0400 -63.0700
SY SYR Syria سوريا AS 34.8021 38.9968
SZ SWZ Eswatini إسواتيني AF -26.5225 31.4659
TC TCA Turks and Caicos Islands جزر توركس وكايكوس NA 21.6900 -71.8000
TD TCD Chad تشاد AF 15.4542 18.7322
TF ATF French Southern Territories الأقاليم الجنوبية الفرنسية AN -49.2500 69.1670
TG TGO Togo توغو AF 8.6195 0.8248
TH THA Thailand تايلاند AS 15.8700 100.9925
TJ TJK Tajikistan طاجيكستان AS 38.8610 71.2761
TK TKL Tokelau توكيلاو OC -9.0000 -172.0000
TL TLS Timor-Leste تيمور الشرقية AS -8.8742 125.7275
TM TKM Turkmenistan تركمانستان AS 38.9697 59.5563
TN TUN Tunisia تونس AF 33.8869 9.5375
TO TON Tonga تونغا OC -20.0000 -175.0000
TR TUR Turkey تركيا AS 38.9637 35.2433
TT TTO Trinidad and Tobago ترينيداد وتوباغو NA 10.6918 -61.2225
TV TUV Tuvalu توفالو OC -7.1095 177.6493
TW TWN Taiwan تايوان AS 23.6978 120.9605
TZ TZA Tanzania تنزانيا AF -6.3690 34.8888
UA UKR Ukraine أوكرانيا EU 48.3794 31.1656
UG UGA Uganda أوغندا AF 1.3733 32.2903
UM UMI United States Minor Outlying Islands جزر الولايات المتحدة النائية OC 19.3000 -166.6000
US USA United States الولايات المتحدة NA 37.0902 -95.7129
UY URY Uruguay أوروغواي SA -32.5228 -55.7658
UZ UZB Uzbekistan أوزبكستان AS 41.3775 64.5853
VA VAT Vatican City الفاتيكان EU 41.9029 12.4534
VC VCT Saint Vincent سانت فنسنت NA 12.9843 -61.2872
VE VEN Venezuela فنزويلا SA 6.4238 -66.5897
VG VGB Virgin Islands, British جزر فيرجن البريطانية NA 18.4200 -64.6200
VI VIR Virgin Islands, U.S. جزر فيرجن الأمريكية NA 18.3400 -64.9300
VN VNM Vietnam فيتنام AS 14.0583 108.2772
VU VUT Vanuatu فانواتو OC -15.3767 166.9592
WF WLF Wallis and Futuna جزر والس وفوتونا OC -13.3000 -176.2000
WS WSM Samoa ساموا OC -13.7590 -172.1046
YE YEM Yemen اليمن AS 15.5527 48.5164
YT MYT Mayotte مايوت AF -12.8333 45.1667
ZA ZAF South Africa جنوب أفريقيا AF -30.5595 22.9375
ZM ZMB Zambia زامبيا AF -13.1339 27.8493
ZW ZWE Zimbabwe زيمبابوي AF -19.0154 29.1549
''';
}
