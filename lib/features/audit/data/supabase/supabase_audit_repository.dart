import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/data/input_validators.dart';
import '../../../../core/data/supabase/supabase_helpers.dart';
import '../../../../core/result/result.dart';
import '../../../../core/types/query_filters.dart';
import '../../domain/entities/activity_log.dart';
import '../../domain/entities/audit_enums.dart';
import '../../domain/repositories/audit_repository.dart';
import 'activity_log_supabase_dto.dart';

/// PostgreSQL / Supabase implementation of [AuditRepository].
///
/// Backed by append-only `activity_logs` (RLS permits `SELECT` and `INSERT`,
/// forbidding `UPDATE` and `DELETE`).
final class SupabaseAuditRepository implements AuditRepository {
  SupabaseAuditRepository(this._client);

  final SupabaseClient _client;

  /// Best-effort helper invoked by sibling Supabase repositories after non-RPC
  /// mutations (RPCs write their `activity_logs` rows atomically inside SQL).
  static Future<void> tryRecordAudit(
    SupabaseClient client, {
    String? actorEmployeeId,
    required AuditAction action,
    required AuditEntityType entityType,
    required String entityId,
    required String description,
    Map<String, Object?>? oldValues,
    Map<String, Object?>? newValues,
  }) async {
    try {
      await client.from(ActivityLogSupabaseDto.tableName).insert(
            ActivityLogSupabaseDto.toInsertMap(
              actorEmployeeId: actorEmployeeId,
              action: action,
              entityType: entityType,
              entityId: entityId,
              description: description,
              oldValues: oldValues,
              newValues: newValues,
            ),
          );
    } catch (_) {
      // Non-RPC mutations should not abort if audit RLS is stricter in setup.
    }
  }

  @override
  Future<Result<ActivityLog>> logActivity({
    String? actorEmployeeId,
    required AuditAction action,
    required AuditEntityType entityType,
    required String entityId,
    required String description,
    Map<String, Object?>? oldValues,
    Map<String, Object?>? newValues,
  }) async {
    final errors = <String, String>{};
    InputValidators.requireNonEmpty(errors, 'entityId', entityId);
    InputValidators.requireNonEmpty(errors, 'description', description);
    final validation = InputValidators.toFailure(errors);
    if (validation != null) return Err<ActivityLog>(validation);

    try {
      final row = await _client
          .from(ActivityLogSupabaseDto.tableName)
          .insert(
            ActivityLogSupabaseDto.toInsertMap(
              actorEmployeeId: actorEmployeeId,
              action: action,
              entityType: entityType,
              entityId: entityId.trim(),
              description: description.trim(),
              oldValues: oldValues,
              newValues: newValues,
            ),
          )
          .select()
          .single();

      return Ok<ActivityLog>(ActivityLogSupabaseDto.fromSupabase(row));
    } catch (error) {
      return Err<ActivityLog>(
        SupabaseHelpers.mapError(error, entityName: 'ActivityLog'),
      );
    }
  }

  @override
  Future<Result<List<ActivityLog>>> getActivityLogs({
    String? actorEmployeeId,
    AuditEntityType? entityType,
    String? entityId,
    AuditAction? action,
    DateRangeFilter? dateRange,
    int limit = 100,
  }) async {
    final rangeFailure = InputValidators.validateDateRange(dateRange);
    if (rangeFailure != null) return Err<List<ActivityLog>>(rangeFailure);

    try {
      var query = _client.from(ActivityLogSupabaseDto.tableName).select();

      if (actorEmployeeId != null) {
        query = query.eq('actor_employee_id', actorEmployeeId);
      }
      if (entityType != null) {
        query = query.eq('entity_type', entityType.dbValue);
      }
      if (entityId != null) {
        query = query.eq('entity_id', entityId);
      }
      if (action != null) {
        query = query.eq('action', action.dbValue);
      }

      final rows = await query
          .order('created_at', ascending: false)
          .limit(limit * 2);

      var logs = rows.map(ActivityLogSupabaseDto.fromSupabase).toList();
      if (dateRange != null) {
        logs = logs
            .where((entry) => dateRange.contains(entry.createdAt))
            .toList();
      }
      if (logs.length > limit) {
        logs = logs.sublist(0, limit);
      }
      return Ok<List<ActivityLog>>(logs);
    } catch (error) {
      return Err<List<ActivityLog>>(
        SupabaseHelpers.mapError(error, entityName: 'ActivityLog'),
      );
    }
  }

  @override
  Stream<List<ActivityLog>> watchActivityLogs({
    AuditEntityType? entityType,
    String? entityId,
    int limit = 50,
  }) {
    final streamBuilder = _client
        .from(ActivityLogSupabaseDto.tableName)
        .stream(primaryKey: const <String>['activity_log_id']);

    // SupabaseStreamBuilder supports at most one `.eq(...)` filter before `.order()`.
    final filtered = entityType != null
        ? streamBuilder.eq('entity_type', entityType.dbValue)
        : (entityId != null
            ? streamBuilder.eq('entity_id', entityId)
            : streamBuilder);

    return filtered.order('created_at', ascending: false).limit(limit * 2).map(
      (rows) {
        var logs = rows.map(ActivityLogSupabaseDto.fromSupabase);
        if (entityType != null && entityId != null) {
          logs = logs.where((entry) => entry.entityId == entityId);
        }
        return logs.take(limit).toList(growable: false);
      },
    );
  }
}
