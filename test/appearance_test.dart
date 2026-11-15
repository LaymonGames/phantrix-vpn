import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:phantrix/settings/settings_controller.dart';
import 'package:phantrix/settings/settings_persistence.dart';
import 'package:phantrix/theme/app_theme.dart';
import 'package:phantrix/ui/screens/settings/appearance_panel.dart';
import 'package:phantrix_core/phantrix_core.dart';

Widget _app(SettingsController settings) => MaterialApp(
  theme: AppTheme.dark(animationLevel: 'none'),
  home: Scaffold(
    body: SingleChildScrollView(child: AppearancePanel(settings: settings)),
  ),
);

void main() {
  group('accent colour', () {
    testWidgets('Phantrix green is the default and is marked selected', (
      tester,
    ) async {
      final settings = SettingsController(AppSettings.defaults);
      await tester.pumpWidget(_app(settings));
      expect(settings.data.accentColor, VgAccent.phantrixGreen.toARGB32());
      expect(
        tester.getSemantics(find.bySemanticsLabel('Phantrix green')),
        matchesSemantics(
          label: 'Phantrix green',
          isButton: true,
          isSelected: true,
          hasSelectedState: true,
          hasTapAction: true,
          hasFocusAction: true,
          isFocusable: true,
        ),
      );
    });

    testWidgets('tapping a swatch stores that accent', (tester) async {
      final settings = SettingsController(AppSettings.defaults);
      await tester.pumpWidget(_app(settings));
      await tester.tap(find.bySemanticsLabel('Violet'));
      await tester.pump();
      expect(settings.data.accentColor, 0xFFC084FC);
    });

    testWidgets('the custom dialog stores the chosen hue, and resets', (
      tester,
    ) async {
      final settings = SettingsController(AppSettings.defaults);
      await tester.pumpWidget(_app(settings));
      await tester.tap(find.bySemanticsLabel('Custom colour'));
      await tester.pumpAndSettle();
      expect(find.text('Custom accent'), findsOneWidget);
      await tester.tap(find.text('Use this colour'));
      await tester.pumpAndSettle();
      final custom = settings.data.accentColor;
      expect(
        VgAccent.presets.any((p) => p.color.toARGB32() == custom),
        isFalse,
      );

      await tester.tap(find.bySemanticsLabel('Custom colour'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reset to Phantrix green'));
      await tester.pumpAndSettle();
      expect(settings.data.accentColor, VgAccent.phantrixGreen.toARGB32());
    });

    test('the accent survives a save and load', () {
      final saved = SettingsCodec.encode(
        AppSettings.defaults.copyWith(accentColor: 0xFF38BDF8),
      );
      expect(SettingsCodec.decode(saved).accentColor, 0xFF38BDF8);
    });

    test('a stored accent that is not opaque is ignored', () {
      final saved = SettingsCodec.encode(
        AppSettings.defaults.copyWith(accentColor: 0x1238BDF8),
      );
      expect(
        SettingsCodec.decode(saved).accentColor,
        AppSettings.defaultAccent,
      );
    });
  });

  group('theme', () {
    testWidgets('choosing Light stores the light theme', (tester) async {
      final settings = SettingsController(AppSettings.defaults);
      await tester.pumpWidget(_app(settings));
      await tester.tap(find.text('Light'));
      await tester.pump();
      expect(settings.data.themeMode, 'light');
      await tester.tap(find.text('Dark'));
      await tester.pump();
      expect(settings.data.themeMode, 'dark');
    });

    test('the accent tints the theme it is given', () {
      final violet = AppTheme.dark(
        animationLevel: 'none',
        accent: const Color(0xFFC084FC),
      );
      final green = AppTheme.dark(animationLevel: 'none');
      expect(violet.colorScheme.primary, isNot(green.colorScheme.primary));
      expect(violet.extension<VgDecor>(), isNotNull);
    });
  });
}
