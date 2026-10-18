/// Machine-stable error grouping used across the whole application.
///
/// Codes are deliberately stable strings so they can be surfaced in the UI,
/// written to local logs, and matched by tests without breaking between
/// releases.
library;

enum ErrorGroup {
  network,
  parse,
  validation,
  tunnel,
  permission,
  storage,
  provider,
  configuration,
  unknown,
}

/// A single, non-localisable application error.
///
/// [message] is written for humans and must never contain secrets, private
/// keys, full URLs, DNS names or credential material. Use [detail] only for
/// values that have already passed redaction.
class AppError {
  const AppError({
    required this.group,
    required this.code,
    required this.message,
    this.detail,
    this.cause,
  });

  final ErrorGroup group;
  final String code;
  final String message;
  final Map<String, Object?>? detail;
  final Object? cause;

  static const AppError cancelled = AppError(
    group: ErrorGroup.unknown,
    code: 'cancelled',
    message: 'The operation was cancelled.',
  );

  AppError withCause(Object cause) => AppError(
    group: group,
    code: code,
    message: message,
    detail: detail,
    cause: cause,
  );

  @override
  String toString() => 'AppError(${group.name}:$code: $message)';
}
