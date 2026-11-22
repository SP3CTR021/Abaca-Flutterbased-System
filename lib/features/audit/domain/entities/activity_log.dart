import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import 'audit_enums.dart';

/// Immutable append-only audit trail entry (`activity_logs` table / collection).
///
/// Replaces the unbacked `App\Models\ActivityLog` stub in the Laravel handoff.
///
/// Relationships:
/// - `N:1` nullable child of `employees` (`activity_logs.actor_employee_id`,
///   `ON DELETE SET NULL`) so historical logs survive even if a staff profile
///   is later purged.
@immutable
final class ActivityLog {
  ActivityLog({
    required this.id,
    this.actorEmployeeId,
    required this.action,
    required this.entityType,
    required this.entityId,
    required this.description,
    Map<String, Object?>? oldValues,
    Map<String, Object?>? newValues,
    required this.createdAt,
  })  : oldValues =
            oldValues == null ? null : Map<String, Object?>.unmodifiable(oldValues),
        newValues =
            newValues == null ? null : Map<String, Object?>.unmodifiable(newValues);

  /// Primary key (`activity_log_id`).
  final String id;

  /// Employee who performed the operation (`ON DELETE SET NULL`).
  final String? actorEmployeeId;
  final AuditAction action;
  final AuditEntityType entityType;

  /// Target primary key of the affected entity.
  final String entityId;
  final String description;
  final Map<String, Object?>? oldValues;
  final Map<String, Object?>? newValues;
  final DateTime createdAt;

  static const DeepCollectionEquality _deepEquality = DeepCollectionEquality();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ActivityLog &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          actorEmployeeId == other.actorEmployeeId &&
          action == other.action &&
          entityType == other.entityType &&
          entityId == other.entityId &&
          description == other.description &&
          _deepEquality.equals(oldValues, other.oldValues) &&
          _deepEquality.equals(newValues, other.newValues) &&
          createdAt == other.createdAt;

  @override
  int get hashCode => Object.hash(
        runtimeType,
        id,
        actorEmployeeId,
        action,
        entityType,
        entityId,
        description,
        _deepEquality.hash(oldValues),
        _deepEquality.hash(newValues),
        createdAt,
      );

  @override
  String toString() =>
      'ActivityLog(id: $id, action: ${action.dbValue}, entityType: ${entityType.dbValue}, entityId: $entityId)';
}
