library;

/// Validation issues shared by every protocol parser.
///
/// Kept separate from [AppError] so a config can report *all* issues at once
/// instead of failing on the first one.
import '../core/app_error.dart';

class ValidationIssue {
  const ValidationIssue({
    required this.code,
    required this.message,
    this.severity = IssueSeverity.error,
    this.field,
    this.detail,
  });

  final String code;
  final String message;
  final IssueSeverity severity;
  final String? field;
  final Map<String, Object?>? detail;

  bool get isError => severity == IssueSeverity.error;

  AppError asError() => AppError(
    group: ErrorGroup.validation,
    code: code,
    message: message,
    detail: detail,
  );

  @override
  String toString() => message;
}

enum IssueSeverity { info, warning, error }

/// The result of a validation pass: a (possibly empty) list of issues.
class ValidationResult {
  const ValidationResult(this.issues);

  final List<ValidationIssue> issues;

  static const ValidationResult valid = ValidationResult([]);

  bool get isValid => issues.every((i) => !i.isError);

  List<ValidationIssue> get errors =>
      issues.where((i) => i.isError).toList(growable: false);

  List<ValidationIssue> get warnings => issues
      .where((i) => i.severity == IssueSeverity.warning)
      .toList(growable: false);

  AppError? get asError => isValid
      ? null
      : AppError(
          group: ErrorGroup.validation,
          code: 'validation.failed',
          message: errors.map((e) => e.message).join(' '),
          detail: {'issues': errors.map((e) => e.code).toList(growable: false)},
        );
}
