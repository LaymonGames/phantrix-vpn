import '../core/app_error.dart';

/// Minimal result type used across the domain layer.
///
/// We avoid `dartz`/`fpdart` style FP kits to keep the dependency surface
/// small and reviewable; a sealed class gives the same exhaustiveness
/// guarantees.
sealed class Result<T> {
  const Result();

  const factory Result.ok(T value) = Ok<T>;

  const factory Result.err(AppError error) = Err<T>;

  R when<R>({
    required R Function(T value) ok,
    required R Function(AppError error) err,
  }) {
    final self = this;
    return switch (self) {
      Ok<T>() => ok(self.value),
      Err<T>() => err(self.error),
    };
  }

  bool get isOk => this is Ok<T>;

  T? get valueOrNull => switch (this) {
    Ok<T>(:final value) => value,
    Err<T>() => null,
  };

  AppError? get errorOrNull => switch (this) {
    Ok<T>() => null,
    Err<T>(:final error) => error,
  };

  T get valueOr => switch (this) {
    Ok<T>(:final value) => value,
    Err<T>() => throw StateError('Result is an error: $errorOrNull'),
  };
}

final class Ok<T> extends Result<T> {
  const Ok(this.value);

  final T value;

  @override
  String toString() => 'Ok($value)';
}

final class Err<T> extends Result<T> {
  const Err(this.error);

  final AppError error;

  @override
  String toString() => 'Err($error)';
}

/// Convenience helpers so call sites stay terse.
Result<T> ok<T>(T value) => Result.ok(value);

Result<T> err<T>(AppError error) => Result.err(error);
