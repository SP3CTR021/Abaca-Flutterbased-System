import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import '../utils/decimal_precision.dart';

/// Base backend-agnostic failure hierarchy returned inside `Result.err(...)`.
///
/// Repository implementations translate Postgres/Supabase errors and Cloud
/// Firestore/FirebaseAuth exceptions into these typed failures so domain,
/// view models, and tests observe uniform error semantics across backends.
@immutable
sealed class AppFailure implements Exception {
  const AppFailure({
    required this.message,
    this.code,
    this.cause,
  });

  final String message;
  final String? code;
  final Object? cause;

  @override
  String toString() => '$runtimeType(code: $code, message: $message)';
}

/// Raised when an expected entity or record does not exist.
final class NotFoundFailure extends AppFailure {
  const NotFoundFailure({
    required this.entityName,
    required this.entityId,
    required super.message,
    super.code = 'not_found',
    super.cause,
  });

  final String entityName;
  final String entityId;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NotFoundFailure &&
          runtimeType == other.runtimeType &&
          entityName == other.entityName &&
          entityId == other.entityId &&
          message == other.message &&
          code == other.code;

  @override
  int get hashCode => Object.hash(runtimeType, entityName, entityId, message, code);
}

/// Raised when input data violates domain validation constraints.
final class ValidationFailure extends AppFailure {
  ValidationFailure({
    required super.message,
    Map<String, String> fieldErrors = const <String, String>{},
    super.code = 'validation_error',
    super.cause,
  }) : fieldErrors = Map<String, String>.unmodifiable(fieldErrors);

  final Map<String, String> fieldErrors;

  static const MapEquality<String, String> _mapEquality =
      MapEquality<String, String>();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ValidationFailure &&
          runtimeType == other.runtimeType &&
          message == other.message &&
          code == other.code &&
          _mapEquality.equals(fieldErrors, other.fieldErrors);

  @override
  int get hashCode => Object.hash(
        runtimeType,
        message,
        code,
        _mapEquality.hash(fieldErrors),
      );
}

/// Raised on uniqueness conflicts (`email`, `abaca_type`, 1:1 `delivery.order_id`)
/// or `ON DELETE RESTRICT` violations when a record is still referenced.
final class ConflictFailure extends AppFailure {
  const ConflictFailure({
    required super.message,
    super.code = 'conflict',
    super.cause,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ConflictFailure &&
          runtimeType == other.runtimeType &&
          message == other.message &&
          code == other.code;

  @override
  int get hashCode => Object.hash(runtimeType, message, code);
}

/// Raised when a stock fulfillment, delivery, stock-out, or stock-in reversal
/// would leave `inventory.current_stock_kg` below zero.
final class InsufficientStockFailure extends AppFailure {
  const InsufficientStockFailure({
    required this.abacaType,
    required this.availableKg,
    required this.requestedKg,
    required super.message,
    super.code = 'insufficient_stock',
    super.cause,
  });

  final String abacaType;
  final double availableKg;
  final double requestedKg;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is InsufficientStockFailure &&
          runtimeType == other.runtimeType &&
          abacaType == other.abacaType &&
          DecimalPrecision.equals2(availableKg, other.availableKg) &&
          DecimalPrecision.equals2(requestedKg, other.requestedKg) &&
          message == other.message &&
          code == other.code;

  @override
  int get hashCode => Object.hash(
        runtimeType,
        abacaType,
        DecimalPrecision.toMinorUnits(availableKg),
        DecimalPrecision.toMinorUnits(requestedKg),
        message,
        code,
      );
}

/// Raised when an operation is invalid for the entity's current lifecycle state
/// (e.g., completing an already-delivered delivery or cancelling a delivered order).
final class InvalidStateTransitionFailure extends AppFailure {
  const InvalidStateTransitionFailure({
    required this.entityName,
    required this.currentState,
    required this.attemptedAction,
    required super.message,
    super.code = 'invalid_state_transition',
    super.cause,
  });

  final String entityName;
  final String currentState;
  final String attemptedAction;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is InvalidStateTransitionFailure &&
          runtimeType == other.runtimeType &&
          entityName == other.entityName &&
          currentState == other.currentState &&
          attemptedAction == other.attemptedAction &&
          message == other.message &&
          code == other.code;

  @override
  int get hashCode => Object.hash(
        runtimeType,
        entityName,
        currentState,
        attemptedAction,
        message,
        code,
      );
}

/// Raised when the caller is unauthenticated or has an expired session.
final class UnauthorizedFailure extends AppFailure {
  const UnauthorizedFailure({
    required super.message,
    super.code = 'unauthorized',
    super.cause,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UnauthorizedFailure &&
          runtimeType == other.runtimeType &&
          message == other.message &&
          code == other.code;

  @override
  int get hashCode => Object.hash(runtimeType, message, code);
}

/// Raised when the authenticated employee lacks role permission or RLS/rules deny access.
final class PermissionDeniedFailure extends AppFailure {
  const PermissionDeniedFailure({
    required super.message,
    super.code = 'permission_denied',
    super.cause,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PermissionDeniedFailure &&
          runtimeType == other.runtimeType &&
          message == other.message &&
          code == other.code;

  @override
  int get hashCode => Object.hash(runtimeType, message, code);
}

/// Raised when connectivity, timeout, or transient service unavailability occurs.
final class NetworkFailure extends AppFailure {
  const NetworkFailure({
    required super.message,
    super.code = 'network_error',
    super.cause,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NetworkFailure &&
          runtimeType == other.runtimeType &&
          message == other.message &&
          code == other.code;

  @override
  int get hashCode => Object.hash(runtimeType, message, code);
}

/// Fallback failure for unexpected backend or serialization errors.
final class UnknownFailure extends AppFailure {
  const UnknownFailure({
    required super.message,
    super.code = 'unknown_error',
    super.cause,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UnknownFailure &&
          runtimeType == other.runtimeType &&
          message == other.message &&
          code == other.code;

  @override
  int get hashCode => Object.hash(runtimeType, message, code);
}
