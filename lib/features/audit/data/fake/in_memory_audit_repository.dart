import '../../../../core/data/fake/in_memory_database.dart';
import '../../../../core/data/input_validators.dart';
import '../../../../core/result/result.dart';
import '../../../../core/types/query_filters.dart';
import '../../domain/entities/activity_log.dart';
import '../../domain/entities/audit_enums.dart';
import '../../domain/repositories/audit_repository.dart';

/// Pure-Dart in-memory implementation of [AuditRepository].
final class InMemoryAuditRepository implements AuditRepository {
  InMemoryAuditRepository(this._db);

  final InMemoryDatabase _db;

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

    final entry = _db.recordAudit(
      actorEmployeeId: actorEmployeeId,
      action: action,
      entityType: entityType,
      entityId: entityId.trim(),
      description: description.trim(),
      oldValues: oldValues,
      newValues: newValues,
    );
    _db.notify();
    return Ok<ActivityLog>(entry);
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

    final list = _queryLogs(
      actorEmployeeId: actorEmployeeId,
      entityType: entityType,
      entityId: entityId,
      action: action,
      dateRange: dateRange,
      limit: limit,
    );
    return Ok<List<ActivityLog>>(list);
  }

  @override
  Stream<List<ActivityLog>> watchActivityLogs({
    AuditEntityType? entityType,
    String? entityId,
    int limit = 50,
  }) =>
      _db.watch(
        () => _queryLogs(
          entityType: entityType,
          entityId: entityId,
          limit: limit,
        ),
      );

  List<ActivityLog> _queryLogs({
    String? actorEmployeeId,
    AuditEntityType? entityType,
    String? entityId,
    AuditAction? action,
    DateRangeFilter? dateRange,
    required int limit,
  }) {
    final filtered = _db.activityLogs.where((entry) {
      if (actorEmployeeId != null && entry.actorEmployeeId != actorEmployeeId) {
        return false;
      }
      if (entityType != null && entry.entityType != entityType) return false;
      if (entityId != null && entry.entityId != entityId) return false;
      if (action != null && entry.action != action) return false;
      if (dateRange != null && !dateRange.contains(entry.createdAt)) {
        return false;
      }
      return true;
    }).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

    return List<ActivityLog>.unmodifiable(filtered.take(limit));
  }
}
