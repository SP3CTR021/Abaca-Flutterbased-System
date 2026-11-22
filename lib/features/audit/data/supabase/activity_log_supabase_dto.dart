import '../../../../core/data/supabase/supabase_helpers.dart';
import '../../domain/entities/activity_log.dart';
import '../../domain/entities/audit_enums.dart';

/// Supabase DTO mapper for the append-only `activity_logs` table.
abstract final class ActivityLogSupabaseDto {
  static const String tableName = 'activity_logs';

  static ActivityLog fromSupabase(Map<String, dynamic> row) {
    final rawOld = row['old_values'];
    final rawNew = row['new_values'];

    return ActivityLog(
      id: row['activity_log_id'] as String,
      actorEmployeeId: row['actor_employee_id'] as String?,
      action: AuditAction.fromDb(row['action'] as String),
      entityType: AuditEntityType.fromDb(row['entity_type'] as String),
      entityId: row['entity_id'] as String,
      description: row['description'] as String,
      oldValues: rawOld is Map ? Map<String, Object?>.from(rawOld) : null,
      newValues: rawNew is Map ? Map<String, Object?>.from(rawNew) : null,
      createdAt: SupabaseHelpers.parseTimestamp(row['created_at']),
    );
  }

  static Map<String, dynamic> toInsertMap({
    String? actorEmployeeId,
    required AuditAction action,
    required AuditEntityType entityType,
    required String entityId,
    required String description,
    Map<String, Object?>? oldValues,
    Map<String, Object?>? newValues,
  }) =>
      <String, dynamic>{
        'actor_employee_id': actorEmployeeId,
        'action': action.dbValue,
        'entity_type': entityType.dbValue,
        'entity_id': entityId,
        'description': description,
        'old_values': ?oldValues,
        'new_values': ?newValues,
      };
}
