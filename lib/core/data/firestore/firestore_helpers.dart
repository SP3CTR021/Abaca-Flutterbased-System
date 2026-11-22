import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart' hide Order, ListEquality;
import 'package:firebase_auth/firebase_auth.dart';

import '../../errors/app_failure.dart';
import '../../utils/decimal_precision.dart';

/// Shared serialization, search-token, and error-translation helpers for
/// all Cloud Firestore repository implementations.
abstract final class FirestoreHelpers {
  /// Converts a [DateTime] to a Firestore [Timestamp] in UTC.
  static Timestamp toTimestamp(DateTime dt) => Timestamp.fromDate(dt.toUtc());

  /// Normalizes a business date (`DATE` column equivalent) to local midnight
  /// before storing as a [Timestamp] so range queries align across devices.
  static Timestamp toDateOnlyTimestamp(DateTime dt) {
    final local = dt.toLocal();
    return Timestamp.fromDate(DateTime(local.year, local.month, local.day));
  }

  /// Parses Firestore [Timestamp], [DateTime], or ISO string to UTC [DateTime].
  static DateTime fromTimestamp(Object? raw) {
    if (raw is Timestamp) return raw.toDate().toUtc();
    if (raw is DateTime) return raw.toUtc();
    if (raw is String && raw.isNotEmpty) return DateTime.parse(raw).toUtc();
    throw FormatException('Invalid Firestore timestamp value: $raw');
  }

  /// Parses an optional Firestore timestamp into UTC [DateTime] or `null`.
  static DateTime? fromNullableTimestamp(Object? raw) {
    if (raw == null) return null;
    return fromTimestamp(raw);
  }

  /// Parses a Firestore `DATE` field back into local date-only [DateTime].
  static DateTime fromDateOnlyTimestamp(Object? raw) {
    final parsed = fromTimestamp(raw).toLocal();
    return DateTime(parsed.year, parsed.month, parsed.day);
  }

  /// Parses numeric values safely to 2-decimal rounded `double`.
  static double parseDouble(Object? raw, {double fallback = 0.0}) {
    if (raw == null) return fallback;
    if (raw is num) return DecimalPrecision.round2(raw.toDouble());
    if (raw is String) {
      final parsed = double.tryParse(raw.trim());
      if (parsed != null) return DecimalPrecision.round2(parsed);
    }
    throw FormatException('Invalid Firestore numeric value: $raw');
  }

  /// Generates lowercase prefix/word tokens (`>= 2` chars) stored in Firestore
  /// DTOs (`search_tokens`) to work around Firestore's lack of `ILIKE`.
  static List<String> buildSearchTokens(Iterable<String?> parts) {
    final tokens = <String>{};
    for (final part in parts) {
      if (part == null) continue;
      final cleaned = part.trim().toLowerCase();
      if (cleaned.isEmpty) continue;
      for (final word in cleaned.split(RegExp(r'\s+'))) {
        if (word.isEmpty) continue;
        final limit = word.length > 20 ? 20 : word.length;
        for (var len = 2; len <= limit; len++) {
          tokens.add(word.substring(0, len));
        }
        if (word.length == 1) {
          tokens.add(word);
        }
      }
      if (cleaned.length >= 2 && cleaned.length <= 32) {
        tokens.add(cleaned);
      }
    }
    return tokens.take(60).toList(growable: false);
  }

  /// Formats `firstName [middleName] lastName` for denormalized Firestore fields.
  static String formatFullName({
    required String firstName,
    String? middleName,
    required String lastName,
  }) {
    final middle = middleName?.trim();
    if (middle == null || middle.isEmpty) {
      return '$firstName $lastName'.trim();
    }
    return '$firstName $middle $lastName'.trim();
  }

  /// Translates [FirebaseAuthException], [FirebaseException], and network errors
  /// into backend-agnostic [AppFailure] subtypes. Passes [AppFailure] through
  /// unchanged so transactions can abort cleanly with domain failures.
  static AppFailure mapError(
    Object error, {
    String entityName = 'Record',
    String entityId = '',
  }) {
    if (error is AppFailure) return error;

    if (error is FirebaseAuthException) {
      switch (error.code) {
        case 'email-already-in-use':
          return ConflictFailure(
            message: error.message ?? 'Email is already registered.',
            code: 'email_already_in_use',
            cause: error,
          );
        case 'invalid-email':
        case 'weak-password':
          return ValidationFailure(
            message: error.message ?? 'Invalid credential input.',
            cause: error,
          );
        case 'wrong-password':
        case 'user-not-found':
        case 'invalid-credential':
        case 'user-token-expired':
          return UnauthorizedFailure(
            message: error.message ?? 'Invalid authentication credentials.',
            cause: error,
          );
        case 'user-disabled':
          return PermissionDeniedFailure(
            message: error.message ?? 'This employee account is disabled.',
            cause: error,
          );
        case 'network-request-failed':
        case 'too-many-requests':
          return NetworkFailure(
            message: error.message ?? 'Network error during Firebase Auth.',
            cause: error,
          );
        default:
          return UnknownFailure(
            message: error.message ?? error.toString(),
            code: error.code,
            cause: error,
          );
      }
    }

    if (error is FirebaseException) {
      switch (error.code) {
        case 'not-found':
          return NotFoundFailure(
            entityName: entityName,
            entityId: entityId,
            message: error.message ?? '$entityName was not found.',
            cause: error,
          );
        case 'already-exists':
        case 'aborted':
          return ConflictFailure(
            message: error.message ?? 'Concurrent update or uniqueness conflict.',
            cause: error,
          );
        case 'permission-denied':
          return PermissionDeniedFailure(
            message: error.message ?? 'Firestore permission denied.',
            cause: error,
          );
        case 'unauthenticated':
          return UnauthorizedFailure(
            message: error.message ?? 'Authentication required.',
            cause: error,
          );
        case 'unavailable':
        case 'deadline-exceeded':
          return NetworkFailure(
            message: error.message ?? 'Firestore network error.',
            cause: error,
          );
        default:
          return UnknownFailure(
            message: error.message ?? error.toString(),
            code: error.code,
            cause: error,
          );
      }
    }

    if (error is TimeoutException) {
      return NetworkFailure(
        message: 'Timed out communicating with Firebase.',
        cause: error,
      );
    }

    return UnknownFailure(
      message: error.toString(),
      cause: error,
    );
  }
}
