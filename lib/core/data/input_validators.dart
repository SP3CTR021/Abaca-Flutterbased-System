import '../errors/app_failure.dart';
import '../types/query_filters.dart';
import '../utils/decimal_precision.dart';

/// Shared pure-Dart validation helpers used across repositories (Supabase,
/// Firestore, and in-memory fakes) so input validation errors match across
/// every backend.
abstract final class InputValidators {
  static final RegExp _emailPattern = RegExp(
    r'^[^\s@]+@[^\s@]+\.[^\s@]+$',
  );

  /// Adds an error to [errors] if [value] is blank after trimming.
  static void requireNonEmpty(
    Map<String, String> errors,
    String field,
    String? value, {
    String? label,
  }) {
    if (value == null || value.trim().isEmpty) {
      errors[field] = '${label ?? field} is required.';
    }
  }

  /// Validates email format into [errors].
  static void validateEmail(
    Map<String, String> errors,
    String field,
    String? value,
  ) {
    final trimmed = value?.trim() ?? '';
    if (trimmed.isEmpty) {
      errors[field] = 'Email is required.';
      return;
    }
    if (!_emailPattern.hasMatch(trimmed)) {
      errors[field] = 'Enter a valid email address.';
    }
  }

  /// Validates optional or required string max length into [errors].
  static void validateMaxLength(
    Map<String, String> errors,
    String field,
    String? value,
    int maxLength, {
    String? label,
  }) {
    if (value != null && value.length > maxLength) {
      errors[field] =
          '${label ?? field} must be at most $maxLength characters.';
    }
  }

  /// Validates that [value] is strictly greater than zero at 2-decimal precision.
  static void requirePositive(
    Map<String, String> errors,
    String field,
    double value, {
    String? label,
  }) {
    if (value.isNaN || value.isInfinite || DecimalPrecision.toMinorUnits(value) <= 0) {
      errors[field] = '${label ?? field} must be greater than 0.';
    }
  }

  /// Validates that [value] is `>= 0` at 2-decimal precision.
  static void requireNonNegative(
    Map<String, String> errors,
    String field,
    double value, {
    String? label,
  }) {
    if (value.isNaN || value.isInfinite || DecimalPrecision.toMinorUnits(value) < 0) {
      errors[field] = '${label ?? field} cannot be negative.';
    }
  }

  /// Returns a [ValidationFailure] if [errors] is non-empty, else `null`.
  static ValidationFailure? toFailure(
    Map<String, String> errors, {
    String message = 'Validation failed.',
  }) {
    if (errors.isEmpty) return null;
    return ValidationFailure(message: message, fieldErrors: errors);
  }

  /// Validates [DateRangeFilter] bounds.
  static ValidationFailure? validateDateRange(DateRangeFilter? filter) {
    if (filter == null || filter.isValid) return null;
    return ValidationFailure(
      message: 'Start date cannot be after end date.',
      fieldErrors: const <String, String>{
        'dateRange': 'Start date must be on or before end date.',
      },
    );
  }
}
