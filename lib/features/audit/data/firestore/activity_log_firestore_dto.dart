import 'package:cloud_firestore/cloud_firestore.dart' hide Order, ListEquality;

import '../../../../core/data/firestore/firestore_helpers.dart';
import '../../domain/entities/activity_log.dart';
import '../../domain/entities/audit_enums.dart';

/// Cloud Firestore DTO mapper for append-only `activity_logs/{logId}` docs.
abstract final class ActivityLogFirestoreDto {
  static ActivityLog fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data()!;
    final rawOld = data['old_values'];
    final rawNew = data['new_values'];

    return ActivityLog(
      id: doc.id,
      actorEmployeeId: data['actor_employee_id'] as String?,
      action: AuditAction.fromDb(data['action'] as String),
      entityType: AuditEntityType.fromDb(data['entity_type'] as String),
      entityId: data['entity_id'] as String,
      description: data['description'] as String,
      oldValues: rawOld is Map ? Map<String, Object?>.from(rawOld) : null,
      newValues: rawNew is Map ? Map<String, Object?>.from(rawNew) : null,
      createdAt: FirestoreHelpers.fromTimestamp(data['created_at']),
    );
  }

  static Map<String, dynamic> toFirestore({
    String? actorEmployeeId,
    required AuditAction action,
    required AuditEntityType entityType,
    required String entityId,
    required String description,
    Map<String, Object?>? oldValues,
    Map<String, Object?>? newValues,
    required DateTime createdAt,
  }) =>
      <String, dynamic>{
        'actor_employee_id': actorEmployeeId,
        'action': action.dbValue,
        'entity_type': entityType.dbValue,
        'entity_id': entityId,
        'description': description,
        'old_values': oldValues,
        'new_values': newValues,
        'created_at': FirestoreHelpers.toTimestamp(createdAt),
      };
}
