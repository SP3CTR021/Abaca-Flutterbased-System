import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import '../errors/app_failure.dart';

/// Backend-agnostic discriminated union representing either success ([Ok]) or a
/// typed domain failure ([Err]).
@immutable
sealed class Result<T> {
  const Result();

  /// Wraps a successful [value].
  const factory Result.ok(T value) = Ok<T>;

  /// Wraps a typed [failure].
  const factory Result.err(AppFailure failure) = Err<T>;

  /// Returns `true` when this result is [Ok].
  bool get isOk => this is Ok<T>;

  /// Returns `true` when this result is [Err].
  bool get isErr => this is Err<T>;

  /// Returns the success value or `null` if this result is [Err].
  T? get valueOrNull => switch (this) {
        Ok<T>(:final value) => value,
        Err<T>() => null,
      };

  /// Returns the [AppFailure] or `null` if this result is [Ok].
  AppFailure? get failureOrNull => switch (this) {
        Ok<T>() => null,
        Err<T>(:final failure) => failure,
      };

  /// Exhaustively transforms either branch into a single value of type [R].
  R fold<R>(
    R Function(AppFailure failure) onErr,
    R Function(T value) onOk,
  ) =>
      switch (this) {
        Ok<T>(:final value) => onOk(value),
        Err<T>(:final failure) => onErr(failure),
      };

  /// Transforms the contained value when [Ok], preserving [Err] untouched.
  Result<R> map<R>(R Function(T value) transform) => switch (this) {
        Ok<T>(:final value) => Ok<R>(transform(value)),
        Err<T>(:final failure) => Err<R>(failure),
      };

  /// Chains another [Result]-returning computation when [Ok].
  Result<R> flatMap<R>(Result<R> Function(T value) transform) => switch (this) {
        Ok<T>(:final value) => transform(value),
        Err<T>(:final failure) => Err<R>(failure),
      };

  /// Returns the value if [Ok], or throws the underlying [AppFailure].
  T getOrThrow() => switch (this) {
        Ok<T>(:final value) => value,
        Err<T>(:final failure) => throw failure,
      };
}

/// Successful branch of [Result].
final class Ok<T> extends Result<T> {
  const Ok(this.value);

  final T value;

  static const DeepCollectionEquality _equality = DeepCollectionEquality();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Ok<T> &&
          runtimeType == other.runtimeType &&
          _equality.equals(value, other.value);

  @override
  int get hashCode => Object.hash(runtimeType, _equality.hash(value));

  @override
  String toString() => 'Ok($value)';
}

/// Failure branch of [Result].
final class Err<T> extends Result<T> {
  const Err(this.failure);

  final AppFailure failure;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Err<T> &&
          runtimeType == other.runtimeType &&
          failure == other.failure;

  @override
  int get hashCode => Object.hash(runtimeType, failure);

  @override
  String toString() => 'Err($failure)';
}
