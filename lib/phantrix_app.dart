import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'app/app_scope.dart';
import 'app/app_shell.dart';
import 'l10n/strings.dart';
import 'theme/app_theme.dart';
import 'ui/screens/onboarding_screen.dart';

class PhantrixApp extends StatelessWidget {
  const PhantrixApp({required this.scope, super.key});

  final AppScope scope;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: scope.settingsController,
      builder: (context, _) {
        final d = scope.settingsController.data;
        if (!d.privacyNoticeAccepted) {
          return MaterialApp(
            title: 'Phantrix',
            debugShowCheckedModeBanner: false,
            theme: AppTheme.dark(animationLevel: d.animationLevel),
            locale: Locale(d.language),
            supportedLocales: L10n.supportedLocales,
            localizationsDelegates: const [
              GlobalMaterialLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              _L10nDelegate(),
            ],
            home: OnboardingScreen(
              onDone: () => scope.settingsController.update(
                (s) => s.copyWith(
                  privacyNoticeAccepted: true,
                  onboardingComplete: true,
                ),
              ),
            ),
          );
        }
        return MaterialApp(
          title: 'Phantrix',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.dark(animationLevel: d.animationLevel),
          locale: Locale(d.language),
          supportedLocales: L10n.supportedLocales,
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            _L10nDelegate(),
          ],
          builder: (context, child) =>
              _ScaleCap(child: child ?? const SizedBox.shrink()),
          home: ShellWithNavigation(
            scope: scope,
            reducedMotion: d.animationLevel == 'none',
          ),
        );
      },
    );
  }
}

class _L10nDelegate extends LocalizationsDelegate<L10n> {
  const _L10nDelegate();

  @override
  bool isSupported(Locale locale) =>
      L10n.supportedLocales.any((l) => l.languageCode == locale.languageCode);

  @override
  Future<L10n> load(Locale locale) async => L10n(locale.languageCode);

  @override
  bool shouldReload(covariant Object old) => false;
}

/// Caps text scale so a large accessibility setting does not break the layout.
class _ScaleCap extends StatelessWidget {
  const _ScaleCap({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.6);
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: scale),
      child: child,
    );
  }
}
