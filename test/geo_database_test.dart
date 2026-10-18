import 'package:flutter_test/flutter_test.dart';
import 'package:phantrix_core/phantrix_core.dart';

void main() {
  group('GeoDatabase', () {
    test('retains complete multi-word English and Arabic country names', () {
      expect(GeoDatabase.nameOf('AE'), 'United Arab Emirates');
      expect(GeoDatabase.nameOf('AE', 'ar'), 'الإمارات العربية المتحدة');
      expect(GeoDatabase.nameOf('HK'), 'Hong Kong');
      expect(GeoDatabase.nameOf('HK', 'ar'), 'هونغ كونغ');
      expect(GeoDatabase.nameOf('HKG'), 'Hong Kong');
      expect(GeoDatabase.flagOf('HKG'), GeoDatabase.flagOf('HK'));
    });

    test('contains a broad offline country reference without implying server availability', () {
      expect(GeoDatabase.countryCount, 249);
      expect(GeoDatabase.byIso2('HK'), isNotNull);
      expect(GeoDatabase.byIso2('HK')!.iso2, 'HK');
    });
  });
}
