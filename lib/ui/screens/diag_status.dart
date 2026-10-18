part of 'diagnostics_screen.dart';

enum DiagStatus { passed, warning, failed, notTested, notSupported }

extension DiagStatusLabel on DiagStatus {
  /// The verdict's own word, in the user's language.
  ///
  /// The keys are the same ones the "Am I protected?" checks use, so the
  /// two places never call the same verdict by two different names.
  String label(L10n l10n) => switch (this) {
    DiagStatus.passed => l10n.get('checkPassed'),
    DiagStatus.warning => l10n.get('checkWarning'),
    DiagStatus.failed => l10n.get('checkFailed'),
    DiagStatus.notTested => l10n.get('notTested'),
    DiagStatus.notSupported => l10n.get('notSupported'),
  };

  /// The tone this verdict is drawn in.
  ///
  /// The last two are deliberately the neutral tone rather than a colour of
  /// their own: "we did not look" and "we cannot look here" are absences of
  /// information, and painting them like findings would be the one thing
  /// this screen must not do.
  VgTone get tone => switch (this) {
    DiagStatus.passed => VgTone.connected,
    DiagStatus.warning => VgTone.blocked,
    DiagStatus.failed => VgTone.failed,
    DiagStatus.notTested || DiagStatus.notSupported => VgTone.idle,
  };
}

class DiagRow {
  const DiagRow({
    required this.id,
    required this.title,
    required this.status,
    this.value,
    this.detail,
  });

  final String id;
  final String title;
  final DiagStatus status;
  final String? value;
  final String? detail;
}
