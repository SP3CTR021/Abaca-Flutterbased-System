import 'dart:async';
import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../errors/app_failure.dart';
import '../../utils/decimal_precision.dart';

/// Shared serialization and PostgreSQL/GoTrue error translation helpers for
/// all Supabase repository implementations.
abstract final class SupabaseHelpers {
  /// Formats [dt] as an ISO `YYYY-MM-DD` date-only string for Postgres `DATE`.
  static String formatDateOnly(DateTime dt) {
    final local = dt.toLocal();
    final y = local.year.toString().padLeft(4, '0');
    final m = local.month.toString().padLeft(2, '0');
    final d = local.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  /// Parses a Postgres `DATE` (`YYYY-MM-DD`) or ISO string into local midnight.
  static DateTime parseDateOnly(Object? raw) {
    if (raw is DateTime) {
      return DateTime(raw.year, raw.month, raw.day);
    }
    if (raw is String && raw.isNotEmpty) {
      final parsed = DateTime.parse(raw);
      return DateTime(parsed.year, parsed.month, parsed.day);
    }
    throw FormatException('Invalid SQL DATE value: $raw');
  }

  /// Parses a Postgres `TIMESTAMPTZ` / ISO string into a UTC [DateTime].
  static DateTime parseTimestamp(Object? raw) {
    if (raw is DateTime) return raw.toUtc();
    if (raw is String && raw.isNotEmpty) {
      return DateTime.parse(raw).toUtc();
    }
    throw FormatException('Invalid SQL TIMESTAMPTZ value: $raw');
  }

  /// Parses an optional SQL timestamp string, returning `null` if absent.
  static DateTime? parseNullableTimestamp(Object? raw) {
    if (raw == null) return null;
    return parseTimestamp(raw);
  }

  /// Parses Postgres `NUMERIC` (returned as either `num` or `String`) safely to
  /// a 2-decimal rounded `double`.
  static double parseDouble(Object? raw, {double fallback = 0.0}) {
    if (raw == null) return fallback;
    if (raw is num) return DecimalPrecision.round2(raw.toDouble());
    if (raw is String) {
      final parsed = double.tryParse(raw.trim());
      if (parsed != null) return DecimalPrecision.round2(parsed);
    }
    throw FormatException('Invalid SQL numeric value: $raw');
  }

  /// Combines `first_name [middle_name] last_name` from a joined Supabase map.
  static String? formatPersonName(Map<String, dynamic>? row) {
    if (row == null) return null;
    final first = (row['first_name'] as String?)?.trim() ?? '';
    final middle = (row['middle_name'] as String?)?.trim() ?? '';
    final last = (row['last_name'] as String?)?.trim() ?? '';
    final parts = <String>[
      if (first.isNotEmpty) first,
      if (middle.isNotEmpty) middle,
      if (last.isNotEmpty) last,
    ];
    return parts.isEmpty ? null : parts.join(' ');
  }

  /// Translates Supabase/PostgREST/GoTrue exceptions and network errors into
  /// backend-agnostic [AppFailure] subtypes.
  static AppFailure mapError(
    Object error, {
    String entityName = 'Record',
    String entityId = '',
  }) {
    if (error is AppFailure) return error;

    if (error is PostgrestException) {
      return _mapPostgrestException(
        error,
        entityName: entityName,
        entityId: entityId,
      );
    }

    if (error is AuthException) {
      return _mapAuthException(error);
    }

    if (_isNetworkError(error)) {
      return NetworkFailure(
        message: 'Network error while communicating with Supabase.',
        cause: error,
      );
    }

    return UnknownFailure(
      message: error.toString(),
      cause: error,
    );
  }

  static AppFailure _mapPostgrestException(
    PostgrestException error, {
    required String entityName,
    required String entityId,
  }) {
    final code = error.code ?? '';
    final detailMap = _tryParseJsonDetail(error.details);

    switch (code) {
      case 'PGRST116':
        return NotFoundFailure(
          entityName: entityName,
          entityId: entityId,
          message: '$entityName was not found.',
          cause: error,
        );
      case '23505':
        return ConflictFailure(
          message: error.message,
          code: 'unique_violation',
          cause: error,
        );
      case '23503':
        // Distinguish ON DELETE RESTRICT (referenced child rows exist) vs
        // inserting with an invalid parent FK.
        return ConflictFailure(
          message:
              'Operation blocked by referential integrity constraint ($entityName).',
          code: 'foreign_key_violation',
          cause: error,
        );
      case '23514':
      case '22P02':
      case '23502':
        return ValidationFailure(
          message: error.message,
          cause: error,
        );
      case '42501':
        return PermissionDeniedFailure(
          message: error.message,
          cause: error,
        );
      case 'P0002':
        return NotFoundFailure(
          entityName: (detailMap['entity_name'] as String?) ?? entityName,
          entityId: (detailMap['entity_id'] as String?) ?? entityId,
          message: error.message,
          cause: error,
        );
      case 'P0003':
        return InsufficientStockFailure(
          abacaType: (detailMap['abaca_type'] as String?) ?? 'unknown',
          availableKg: parseDouble(detailMap['available_kg']),
          requestedKg: parseDouble(detailMap['requested_kg']),
          message: error.message,
          cause: error,
        );
      case 'P0004':
        return InvalidStateTransitionFailure(
          entityName: (detailMap['entity_name'] as String?) ?? entityName,
          currentState: (detailMap['current_state'] as String?) ?? 'unknown',
          attemptedAction:
              (detailMap['attempted_action'] as String?) ?? 'transition',
          message: error.message,
          cause: error,
        );
      case 'P0005':
        return ValidationFailure(
          message: error.message,
          cause: error,
        );
      case 'P0006':
        return ConflictFailure(
          message: error.message,
          cause: error,
        );
      default:
        return UnknownFailure(
          message: error.message,
          code: code.isEmpty ? null : code,
          cause: error,
        );
    }
  }

  static AppFailure _mapAuthException(AuthException error) {
    if (error is AuthRetryableFetchException) {
      return NetworkFailure(
        message: 'Network error during authentication.',
        cause: error,
      );
    }
    if (error is AuthSessionMissingException) {
      return UnauthorizedFailure(
        message: error.message,
        cause: error,
      );
    }

    final code = (error.code ?? '').toLowerCase();
    final msgLower = error.message.toLowerCase();

    if (code == 'user_already_exists' ||
        code == 'email_exists' ||
        msgLower.contains('already registered') ||
        msgLower.contains('already exists')) {
      return ConflictFailure(
        message: error.message,
        code: 'email_already_in_use',
        cause: error,
      );
    }
    if (code == 'invalid_credentials' ||
        msgLower.contains('invalid login credentials')) {
      return UnauthorizedFailure(
        message: 'Invalid email or password.',
        cause: error,
      );
    }
    if (code == 'weak_password' ||
        code == 'validation_failed' ||
        msgLower.contains('password')) {
      return ValidationFailure(
        message: error.message,
        cause: error,
      );
    }
    if (error.statusCode == '401') {
      return UnauthorizedFailure(message: error.message, cause: error);
    }
    if (error.statusCode == '403') {
      return PermissionDeniedFailure(message: error.message, cause: error);
    }
    return UnknownFailure(
      message: error.message,
      code: error.code,
      cause: error,
    );
  }

  static Map<String, dynamic> _tryParseJsonDetail(Object? rawDetails) {
    if (rawDetails is Map<String, dynamic>) return rawDetails;
    if (rawDetails is String && rawDetails.trim().startsWith('{')) {
      try {
        final decoded = jsonDecode(rawDetails);
        if (decoded is Map<String, dynamic>) return decoded;
      } catch (_) {
        return const <String, dynamic>{};
      }
    }
    return const <String, dynamic>{};
  }

  static bool _isNetworkError(Object error) {
    if (error is TimeoutException) return true;
    final typeName = error.runtimeType.toString();
    return typeName.contains('SocketException') ||
        typeName.contains('ClientException') ||
        typeName.contains('HandshakeException');
  }
}
