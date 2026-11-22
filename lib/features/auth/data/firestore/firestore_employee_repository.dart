import 'package:cloud_firestore/cloud_firestore.dart' hide Order, ListEquality;

import '../../../../core/data/firestore/firestore_collections.dart';
import '../../../../core/data/firestore/firestore_helpers.dart';
import '../../../../core/data/input_validators.dart';
import '../../../../core/errors/app_failure.dart';
import '../../../../core/result/result.dart';
import '../../../audit/data/firestore/firestore_audit_repository.dart';
import '../../../audit/domain/entities/audit_enums.dart';
import '../../domain/entities/employee.dart';
import '../../domain/entities/employee_role.dart';
import '../../domain/repositories/employee_repository.dart';
import 'employee_firestore_dto.dart';

/// Cloud Firestore implementation of [EmployeeRepository].
///
/// Workarounds for Firestore relational limitations:
/// - `deleteEmployee` checks all 6 referencing collections (`orders`,
///   `stock_ins`, `stock_outs`, `deliveries`, `expenses`, `collectionGroup('payments')`)
///   to mirror PostgreSQL `ON DELETE RESTRICT`.
/// - `updateEmployee` batch-syncs denormalized `employee_name` onto orders,
///   stock_ins, stock_outs, deliveries, and expenses when the employee's name changes.
final class FirestoreEmployeeRepository implements EmployeeRepository {
  FirestoreEmployeeRepository(this._firestore);

  final FirebaseFirestore _firestore;

  CollectionReference<Map<String, dynamic>> get _collection =>
      _firestore.collection(FirestoreCollections.employees);

  @override
  Future<Result<Employee>> getEmployeeById(String id) async {
    try {
      final doc = await _collection.doc(id).get();
      if (!doc.exists || doc.data() == null) {
        return Err<Employee>(
          NotFoundFailure(
            entityName: 'Employee',
            entityId: id,
            message: 'Employee $id was not found.',
          ),
        );
      }
      return Ok<Employee>(EmployeeFirestoreDto.fromFirestore(doc));
    } catch (error) {
      return Err<Employee>(
        FirestoreHelpers.mapError(error, entityName: 'Employee', entityId: id),
      );
    }
  }

  @override
  Future<Result<Employee?>> getEmployeeByEmail(String email) async {
    final normalized = email.trim().toLowerCase();
    if (normalized.isEmpty) return const Ok<Employee?>(null);

    try {
      final snapshot = await _collection
          .where('email_lower', isEqualTo: normalized)
          .limit(1)
          .get();
      if (snapshot.docs.isEmpty) return const Ok<Employee?>(null);
      return Ok<Employee?>(
        EmployeeFirestoreDto.fromFirestore(snapshot.docs.first),
      );
    } catch (error) {
      return Err<Employee?>(
        FirestoreHelpers.mapError(error, entityName: 'Employee'),
      );
    }
  }

  @override
  Future<Result<List<Employee>>> getEmployees({
    EmployeeRole? role,
    bool? isActive,
  }) async {
    try {
      Query<Map<String, dynamic>> query = _collection;
      if (role != null) {
        query = query.where('role', isEqualTo: role.dbValue);
      }
      if (isActive != null) {
        query = query.where('is_active', isEqualTo: isActive);
      }

      final snapshot = await query.orderBy('last_name', descending: false).get();
      final list = snapshot.docs
          .map(EmployeeFirestoreDto.fromFirestore)
          .toList()
        ..sort((a, b) {
          final lastCmp = a.lastName.compareTo(b.lastName);
          return lastCmp != 0 ? lastCmp : a.firstName.compareTo(b.firstName);
        });
      return Ok<List<Employee>>(List<Employee>.unmodifiable(list));
    } catch (error) {
      return Err<List<Employee>>(
        FirestoreHelpers.mapError(error, entityName: 'Employee'),
      );
    }
  }

  @override
  Stream<List<Employee>> watchEmployees({
    EmployeeRole? role,
    bool? isActive,
  }) {
    Query<Map<String, dynamic>> query = _collection;
    if (role != null) {
      query = query.where('role', isEqualTo: role.dbValue);
    }
    if (isActive != null) {
      query = query.where('is_active', isEqualTo: isActive);
    }

    return query.orderBy('last_name', descending: false).snapshots().map(
          (snapshot) => snapshot.docs
              .map(EmployeeFirestoreDto.fromFirestore)
              .toList(growable: false),
        );
  }

  @override
  Future<Result<Employee>> updateEmployee(
    Employee employee, {
    String? actorEmployeeId,
  }) async {
    final errors = <String, String>{};
    InputValidators.requireNonEmpty(errors, 'firstName', employee.firstName);
    InputValidators.requireNonEmpty(errors, 'lastName', employee.lastName);
    InputValidators.validateEmail(errors, 'email', employee.email);
    final validation = InputValidators.toFailure(errors);
    if (validation != null) return Err<Employee>(validation);

    try {
      final docRef = _collection.doc(employee.id);
      final now = DateTime.now().toUtc();
      String? previousFullName;

      final updated = await _firestore.runTransaction<Employee>((tx) async {
        final snapshot = await tx.get(docRef);
        if (!snapshot.exists || snapshot.data() == null) {
          throw NotFoundFailure(
            entityName: 'Employee',
            entityId: employee.id,
            message: 'Employee ${employee.id} was not found.',
          );
        }

        final previous = EmployeeFirestoreDto.fromFirestore(snapshot);
        previousFullName = previous.fullName;

        final next = employee.copyWith(
          email: employee.email.trim().toLowerCase(),
          createdAt: previous.createdAt,
          updatedAt: now,
        );

        tx.update(
          docRef,
          EmployeeFirestoreDto.toFirestore(
            firstName: next.firstName,
            middleName: next.middleName,
            lastName: next.lastName,
            email: next.email,
            role: next.role,
            isActive: next.isActive,
            createdAt: previous.createdAt,
            updatedAt: now,
          ),
        );

        FirestoreAuditRepository.setAuditInTransaction(
          tx,
          _firestore,
          actorEmployeeId: actorEmployeeId,
          action: AuditAction.updated,
          entityType: AuditEntityType.employee,
          entityId: next.id,
          description: 'Updated employee ${next.fullName}.',
          oldValues: <String, Object?>{
            'role': previous.role.dbValue,
            'is_active': previous.isActive,
          },
          newValues: <String, Object?>{
            'role': next.role.dbValue,
            'is_active': next.isActive,
          },
          timestamp: now,
        );

        return next;
      });

      if (previousFullName != null && previousFullName != updated.fullName) {
        await _syncDenormalizedEmployeeName(updated.id, updated.fullName);
      }

      return Ok<Employee>(updated);
    } catch (error) {
      return Err<Employee>(
        FirestoreHelpers.mapError(
          error,
          entityName: 'Employee',
          entityId: employee.id,
        ),
      );
    }
  }

  @override
  Future<Result<Employee>> setEmployeeActive({
    required String id,
    required bool isActive,
    String? actorEmployeeId,
  }) async {
    try {
      final docRef = _collection.doc(id);
      final now = DateTime.now().toUtc();

      final updated = await _firestore.runTransaction<Employee>((tx) async {
        final snapshot = await tx.get(docRef);
        if (!snapshot.exists || snapshot.data() == null) {
          throw NotFoundFailure(
            entityName: 'Employee',
            entityId: id,
            message: 'Employee $id was not found.',
          );
        }

        final existing = EmployeeFirestoreDto.fromFirestore(snapshot);
        final next = existing.copyWith(isActive: isActive, updatedAt: now);

        tx.update(docRef, <String, dynamic>{
          'is_active': isActive,
          'updated_at': FirestoreHelpers.toTimestamp(now),
        });

        FirestoreAuditRepository.setAuditInTransaction(
          tx,
          _firestore,
          actorEmployeeId: actorEmployeeId,
          action: isActive ? AuditAction.restored : AuditAction.archived,
          entityType: AuditEntityType.employee,
          entityId: id,
          description: isActive
              ? 'Restored employee ${next.fullName}.'
              : 'Archived employee ${next.fullName}.',
          timestamp: now,
        );

        return next;
      });

      return Ok<Employee>(updated);
    } catch (error) {
      return Err<Employee>(
        FirestoreHelpers.mapError(error, entityName: 'Employee', entityId: id),
      );
    }
  }

  @override
  Future<Result<void>> deleteEmployee(
    String id, {
    String? actorEmployeeId,
  }) async {
    try {
      final docRef = _collection.doc(id);
      final doc = await docRef.get();
      if (!doc.exists || doc.data() == null) {
        return Err<void>(
          NotFoundFailure(
            entityName: 'Employee',
            entityId: id,
            message: 'Employee $id was not found.',
          ),
        );
      }
      final existing = EmployeeFirestoreDto.fromFirestore(doc);

      // Emulate SQL ON DELETE RESTRICT across all referencing collections.
      final checks = await Future.wait<QuerySnapshot<Map<String, dynamic>>>([
        _firestore
            .collection(FirestoreCollections.orders)
            .where('employee_id', isEqualTo: id)
            .limit(1)
            .get(),
        _firestore
            .collection(FirestoreCollections.stockIns)
            .where('employee_id', isEqualTo: id)
            .limit(1)
            .get(),
        _firestore
            .collection(FirestoreCollections.stockOuts)
            .where('employee_id', isEqualTo: id)
            .limit(1)
            .get(),
        _firestore
            .collection(FirestoreCollections.deliveries)
            .where('employee_id', isEqualTo: id)
            .limit(1)
            .get(),
        _firestore
            .collection(FirestoreCollections.expenses)
            .where('employee_id', isEqualTo: id)
            .limit(1)
            .get(),
        _firestore
            .collectionGroup(FirestoreCollections.paymentsSubcollection)
            .where('employee_id', isEqualTo: id)
            .limit(1)
            .get(),
      ]);

      if (checks.any((snap) => snap.docs.isNotEmpty)) {
        return const Err<void>(
          ConflictFailure(
            message:
                'Cannot delete employee referenced by operational records. Archive instead.',
            code: 'foreign_key_violation',
          ),
        );
      }

      final batch = _firestore.batch();
      batch.delete(docRef);
      FirestoreAuditRepository.setAuditInBatch(
        batch,
        _firestore,
        actorEmployeeId: actorEmployeeId,
        action: AuditAction.deleted,
        entityType: AuditEntityType.employee,
        entityId: id,
        description: 'Deleted employee ${existing.fullName}.',
      );
      await batch.commit();
      return const Ok<void>(null);
    } catch (error) {
      return Err<void>(
        FirestoreHelpers.mapError(error, entityName: 'Employee', entityId: id),
      );
    }
  }

  Future<void> _syncDenormalizedEmployeeName(
    String employeeId,
    String newFullName,
  ) async {
    const collections = <String>[
      FirestoreCollections.orders,
      FirestoreCollections.stockIns,
      FirestoreCollections.stockOuts,
      FirestoreCollections.deliveries,
      FirestoreCollections.expenses,
    ];

    final refs = <DocumentReference<Map<String, dynamic>>>[];
    for (final col in collections) {
      final snap = await _firestore
          .collection(col)
          .where('employee_id', isEqualTo: employeeId)
          .get();
      for (final doc in snap.docs) {
        refs.add(doc.reference);
      }
    }

    for (var i = 0; i < refs.length; i += 400) {
      final batch = _firestore.batch();
      final end = (i + 400 < refs.length) ? i + 400 : refs.length;
      for (var j = i; j < end; j++) {
        batch.update(refs[j], <String, dynamic>{'employee_name': newFullName});
      }
      await batch.commit();
    }
  }
}
