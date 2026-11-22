import '../../../../core/result/result.dart';
import '../../../../core/types/query_filters.dart';
import '../entities/activity_log.dart';
import '../entities/audit_enums.dart';

/// Append-only audit repository (`activity_logs` table / root collection).
///
/// Security rules / RLS prohibit updates and deletes on audit records; entries
/// are created alongside mutations or via [logActivity].
abstract interface class AuditRepository {
  /// Appends a new immutable [ActivityLog] entry.
  Future<Result<ActivityLog>> logActivity({
    String? actorEmployeeId,
    required AuditAction action,
    required AuditEntityType entityType,
    required String entityId,
    required String description,
    Map<String, Object?>? oldValues,
    Map<String, Object?>? newValues,
  });

  /// Queries audit trail records ordered newest-first.
  Future<Result<List<ActivityLog>>> getActivityLogs({
    String? actorEmployeeId,
    AuditEntityType? entityType,
    String? entityId,
    AuditAction? action,
    DateRangeFilter? dateRange,
    int limit = 100,
  });

  /// Real-time stream of recent audit events ordered newest-first.
  Stream<List<ActivityLog>> watchActivityLogs({
    AuditEntityType? entityType,
    String? entityId,
    int limit = 50,
  });
}
