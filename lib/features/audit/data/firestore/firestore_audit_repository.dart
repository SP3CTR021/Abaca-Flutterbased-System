import 'package:cloud_firestore/cloud_firestore.dart' hide Order, ListEquality;

import '../../../../core/data/firestore/firestore_collections.dart';
import '../../../../core/data/firestore/firestore_helpers.dart';
import '../../../../core/data/input_validators.dart';
import '../../../../core/result/result.dart';
import '../../../../core/types/query_filters.dart';
import '../../domain/entities/activity_log.dart';
import '../../domain/entities/audit_enums.dart';
import '../../domain/repositories/audit_repository.dart';
import 'activity_log_firestore_dto.dart';

/// Cloud Firestore implementation of [AuditRepository].
///
/// Security rules make `activity_logs` strictly append-only (`create` allowed
/// for active employees; `update` and `delete` denied).
final class FirestoreAuditRepository implements AuditRepository {
  FirestoreAuditRepository(this._firestore);

  final FirebaseFirestore _firestore;

  CollectionReference<Map<String, dynamic>> get _collection =>
      _firestore.collection(FirestoreCollections.activityLogs);

  /// Atomically appends an audit document inside an existing [Transaction].
  static void setAuditInTransaction(
    Transaction transaction,
    FirebaseFirestore firestore, {
    String? actorEmployeeId,
    required AuditAction action,
    required AuditEntityType entityType,
    required String entityId,
    required String description,
    Map<String, Object?>? oldValues,
    Map<String, Object?>? newValues,
    DateTime? timestamp,
  }) {
    final docRef = firestore.collection(FirestoreCollections.activityLogs).doc();
    transaction.set(
      docRef,
      ActivityLogFirestoreDto.toFirestore(
        actorEmployeeId: actorEmployeeId,
        action: action,
        entityType: entityType,
        entityId: entityId,
        description: description,
        oldValues: oldValues,
        newValues: newValues,
        createdAt: timestamp ?? DateTime.now().toUtc(),
      ),
    );
  }

  /// Appends an audit document inside an existing [WriteBatch].
  static void setAuditInBatch(
    WriteBatch batch,
    FirebaseFirestore firestore, {
    String? actorEmployeeId,
    required AuditAction action,
    required AuditEntityType entityType,
    required String entityId,
    required String description,
    Map<String, Object?>? oldValues,
    Map<String, Object?>? newValues,
    DateTime? timestamp,
  }) {
    final docRef = firestore.collection(FirestoreCollections.activityLogs).doc();
    batch.set(
      docRef,
      ActivityLogFirestoreDto.toFirestore(
        actorEmployeeId: actorEmployeeId,
        action: action,
        entityType: entityType,
        entityId: entityId,
        description: description,
        oldValues: oldValues,
        newValues: newValues,
        createdAt: timestamp ?? DateTime.now().toUtc(),
      ),
    );
  }

  /// Best-effort audit write outside a transaction (e.g. sign-in / sign-out).
  static Future<void> tryRecordAudit(
    FirebaseFirestore firestore, {
    String? actorEmployeeId,
    required AuditAction action,
    required AuditEntityType entityType,
    required String entityId,
    required String description,
    Map<String, Object?>? oldValues,
    Map<String, Object?>? newValues,
  }) async {
    try {
      await firestore.collection(FirestoreCollections.activityLogs).add(
            ActivityLogFirestoreDto.toFirestore(
              actorEmployeeId: actorEmployeeId,
              action: action,
              entityType: entityType,
              entityId: entityId,
              description: description,
              oldValues: oldValues,
              newValues: newValues,
              createdAt: DateTime.now().toUtc(),
            ),
          );
    } catch (_) {
      // Best-effort auth event logging should not block sign-out.
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
      final now = DateTime.now().toUtc();
      final docRef = _collection.doc();
      await docRef.set(
        ActivityLogFirestoreDto.toFirestore(
          actorEmployeeId: actorEmployeeId,
          action: action,
          entityType: entityType,
          entityId: entityId.trim(),
          description: description.trim(),
          oldValues: oldValues,
          newValues: newValues,
          createdAt: now,
        ),
      );

      final created = ActivityLog(
        id: docRef.id,
        actorEmployeeId: actorEmployeeId,
        action: action,
        entityType: entityType,
        entityId: entityId.trim(),
        description: description.trim(),
        oldValues: oldValues,
        newValues: newValues,
        createdAt: now,
      );
      return Ok<ActivityLog>(created);
    } catch (error) {
      return Err<ActivityLog>(
        FirestoreHelpers.mapError(error, entityName: 'ActivityLog'),
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
      Query<Map<String, dynamic>> query = _collection;
      // Pick one composite index root and refine extra filters in memory to
      // avoid combinatorial index explosion in Firestore.
      if (entityType != null) {
        query = query.where('entity_type', isEqualTo: entityType.dbValue);
        if (entityId != null) {
          query = query.where('entity_id', isEqualTo: entityId);
        }
      } else if (actorEmployeeId != null) {
        query = query.where('actor_employee_id', isEqualTo: actorEmployeeId);
      } else if (action != null) {
        query = query.where('action', isEqualTo: action.dbValue);
      }

      final snapshot = await query
          .orderBy('created_at', descending: true)
          .limit(limit * 3)
          .get();

      var logs = snapshot.docs.map(ActivityLogFirestoreDto.fromFirestore);
      if (actorEmployeeId != null) {
        logs = logs.where((e) => e.actorEmployeeId == actorEmployeeId);
      }
      if (entityId != null) {
        logs = logs.where((e) => e.entityId == entityId);
      }
      if (action != null) {
        logs = logs.where((e) => e.action == action);
      }
      if (dateRange != null) {
        logs = logs.where((e) => dateRange.contains(e.createdAt));
      }
      return Ok<List<ActivityLog>>(logs.take(limit).toList(growable: false));
    } catch (error) {
      return Err<List<ActivityLog>>(
        FirestoreHelpers.mapError(error, entityName: 'ActivityLog'),
      );
    }
  }

  @override
  Stream<List<ActivityLog>> watchActivityLogs({
    AuditEntityType? entityType,
    String? entityId,
    int limit = 50,
  }) {
    Query<Map<String, dynamic>> query = _collection;
    if (entityType != null) {
      query = query.where('entity_type', isEqualTo: entityType.dbValue);
      if (entityId != null) {
        query = query.where('entity_id', isEqualTo: entityId);
      }
    }

    return query
        .orderBy('created_at', descending: true)
        .limit(limit * 2)
        .snapshots()
        .map((snapshot) {
      var logs = snapshot.docs.map(ActivityLogFirestoreDto.fromFirestore);
      if (entityType == null && entityId != null) {
        logs = logs.where((e) => e.entityId == entityId);
      }
      return logs.take(limit).toList(growable: false);
    });
  }
}
