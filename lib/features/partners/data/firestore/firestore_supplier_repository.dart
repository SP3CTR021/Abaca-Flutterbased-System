import 'package:cloud_firestore/cloud_firestore.dart' hide Order, ListEquality;

import '../../../../core/data/firestore/firestore_collections.dart';
import '../../../../core/data/firestore/firestore_helpers.dart';
import '../../../../core/data/input_validators.dart';
import '../../../../core/errors/app_failure.dart';
import '../../../../core/result/result.dart';
import '../../../audit/data/firestore/firestore_audit_repository.dart';
import '../../../audit/domain/entities/audit_enums.dart';
import '../../domain/entities/supplier.dart';
import '../../domain/repositories/supplier_repository.dart';
import 'supplier_firestore_dto.dart';

/// Cloud Firestore implementation of [SupplierRepository].
///
/// Workarounds:
/// - `search_tokens` array enables partial-name search (`arrayContains`).
/// - `updateSupplier` syncs denormalized `supplier_name` onto `stock_ins` when changed.
/// - `deleteSupplier` checks `stock_ins` before deleting (`ON DELETE RESTRICT`).
final class FirestoreSupplierRepository implements SupplierRepository {
  FirestoreSupplierRepository(this._firestore);

  final FirebaseFirestore _firestore;

  CollectionReference<Map<String, dynamic>> get _collection =>
      _firestore.collection(FirestoreCollections.suppliers);

  @override
  Future<Result<Supplier>> createSupplier({
    required String firstName,
    String? middleName,
    required String lastName,
    String? contactNumber,
    String? address,
    String? actorEmployeeId,
  }) async {
    final errors = <String, String>{};
    InputValidators.requireNonEmpty(errors, 'firstName', firstName);
    InputValidators.requireNonEmpty(errors, 'lastName', lastName);
    InputValidators.validateMaxLength(errors, 'address', address, 500);
    final validation = InputValidators.toFailure(errors);
    if (validation != null) return Err<Supplier>(validation);

    try {
      final docRef = _collection.doc();
      final now = DateTime.now().toUtc();
      final created = Supplier(
        id: docRef.id,
        firstName: firstName.trim(),
        middleName:
            middleName?.trim().isEmpty == true ? null : middleName?.trim(),
        lastName: lastName.trim(),
        contactNumber: contactNumber?.trim().isEmpty == true
            ? null
            : contactNumber?.trim(),
        address: address?.trim().isEmpty == true ? null : address?.trim(),
        isActive: true,
        createdAt: now,
        updatedAt: now,
      );

      final batch = _firestore.batch();
      batch.set(
        docRef,
        SupplierFirestoreDto.toFirestore(
          firstName: created.firstName,
          middleName: created.middleName,
          lastName: created.lastName,
          contactNumber: created.contactNumber,
          address: created.address,
          isActive: created.isActive,
          createdAt: now,
          updatedAt: now,
        ),
      );
      FirestoreAuditRepository.setAuditInBatch(
        batch,
        _firestore,
        actorEmployeeId: actorEmployeeId,
        action: AuditAction.created,
        entityType: AuditEntityType.supplier,
        entityId: created.id,
        description: 'Created supplier ${created.fullName}.',
        timestamp: now,
      );
      await batch.commit();

      return Ok<Supplier>(created);
    } catch (error) {
      return Err<Supplier>(
        FirestoreHelpers.mapError(error, entityName: 'Supplier'),
      );
    }
  }

  @override
  Future<Result<Supplier>> getSupplierById(String id) async {
    try {
      final doc = await _collection.doc(id).get();
      if (!doc.exists || doc.data() == null) {
        return Err<Supplier>(
          NotFoundFailure(
            entityName: 'Supplier',
            entityId: id,
            message: 'Supplier $id was not found.',
          ),
        );
      }
      return Ok<Supplier>(SupplierFirestoreDto.fromFirestore(doc));
    } catch (error) {
      return Err<Supplier>(
        FirestoreHelpers.mapError(error, entityName: 'Supplier', entityId: id),
      );
    }
  }

  @override
  Future<Result<List<Supplier>>> getSuppliers({
    bool? isActive,
    String? searchQuery,
  }) async {
    try {
      final trimmedQuery = searchQuery?.trim().toLowerCase() ?? '';
      Query<Map<String, dynamic>> query = _collection;

      if (trimmedQuery.length >= 2) {
        final firstToken = trimmedQuery.split(RegExp(r'\s+')).first;
        final token = firstToken.length > 20
            ? firstToken.substring(0, 20)
            : firstToken;
        query = query.where('search_tokens', arrayContains: token);
        if (isActive != null) {
          query = query.where('is_active', isEqualTo: isActive);
        }
      } else {
        if (isActive != null) {
          query = query.where('is_active', isEqualTo: isActive);
        }
        query = query.orderBy('last_name', descending: false);
      }

      final snapshot = await query.get();
      var list = snapshot.docs.map(SupplierFirestoreDto.fromFirestore).toList();

      if (trimmedQuery.isNotEmpty) {
        list = list.where((supplier) {
          return supplier.fullName.toLowerCase().contains(trimmedQuery) ||
              (supplier.contactNumber?.toLowerCase().contains(trimmedQuery) ??
                  false) ||
              (supplier.address?.toLowerCase().contains(trimmedQuery) ?? false);
        }).toList();
      }

      list.sort((a, b) {
        final lastCmp = a.lastName.compareTo(b.lastName);
        return lastCmp != 0 ? lastCmp : a.firstName.compareTo(b.firstName);
      });
      return Ok<List<Supplier>>(List<Supplier>.unmodifiable(list));
    } catch (error) {
      return Err<List<Supplier>>(
        FirestoreHelpers.mapError(error, entityName: 'Supplier'),
      );
    }
  }

  @override
  Stream<List<Supplier>> watchSuppliers({bool? isActive}) {
    Query<Map<String, dynamic>> query = _collection;
    if (isActive != null) {
      query = query.where('is_active', isEqualTo: isActive);
    }
    return query.orderBy('last_name', descending: false).snapshots().map(
          (snapshot) => snapshot.docs
              .map(SupplierFirestoreDto.fromFirestore)
              .toList(growable: false),
        );
  }

  @override
  Future<Result<Supplier>> updateSupplier(
    Supplier supplier, {
    String? actorEmployeeId,
  }) async {
    final errors = <String, String>{};
    InputValidators.requireNonEmpty(errors, 'firstName', supplier.firstName);
    InputValidators.requireNonEmpty(errors, 'lastName', supplier.lastName);
    InputValidators.validateMaxLength(
      errors,
      'address',
      supplier.address,
      500,
    );
    final validation = InputValidators.toFailure(errors);
    if (validation != null) return Err<Supplier>(validation);

    try {
      final docRef = _collection.doc(supplier.id);
      final now = DateTime.now().toUtc();
      String? previousFullName;

      final updated = await _firestore.runTransaction<Supplier>((tx) async {
        final snapshot = await tx.get(docRef);
        if (!snapshot.exists || snapshot.data() == null) {
          throw NotFoundFailure(
            entityName: 'Supplier',
            entityId: supplier.id,
            message: 'Supplier ${supplier.id} was not found.',
          );
        }
        final previous = SupplierFirestoreDto.fromFirestore(snapshot);
        previousFullName = previous.fullName;

        final next = supplier.copyWith(
          createdAt: previous.createdAt,
          updatedAt: now,
        );

        tx.update(
          docRef,
          SupplierFirestoreDto.toFirestore(
            firstName: next.firstName,
            middleName: next.middleName,
            lastName: next.lastName,
            contactNumber: next.contactNumber,
            address: next.address,
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
          entityType: AuditEntityType.supplier,
          entityId: next.id,
          description: 'Updated supplier ${next.fullName}.',
          timestamp: now,
        );

        return next;
      });

      if (previousFullName != null && previousFullName != updated.fullName) {
        await _syncDenormalizedSupplierName(updated.id, updated.fullName);
      }

      return Ok<Supplier>(updated);
    } catch (error) {
      return Err<Supplier>(
        FirestoreHelpers.mapError(
          error,
          entityName: 'Supplier',
          entityId: supplier.id,
        ),
      );
    }
  }

  @override
  Future<Result<Supplier>> setSupplierActive({
    required String id,
    required bool isActive,
    String? actorEmployeeId,
  }) async {
    try {
      final docRef = _collection.doc(id);
      final now = DateTime.now().toUtc();

      final updated = await _firestore.runTransaction<Supplier>((tx) async {
        final snapshot = await tx.get(docRef);
        if (!snapshot.exists || snapshot.data() == null) {
          throw NotFoundFailure(
            entityName: 'Supplier',
            entityId: id,
            message: 'Supplier $id was not found.',
          );
        }
        final existing = SupplierFirestoreDto.fromFirestore(snapshot);
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
          entityType: AuditEntityType.supplier,
          entityId: id,
          description: isActive
              ? 'Restored supplier ${next.fullName}.'
              : 'Archived supplier ${next.fullName}.',
          timestamp: now,
        );
        return next;
      });

      return Ok<Supplier>(updated);
    } catch (error) {
      return Err<Supplier>(
        FirestoreHelpers.mapError(error, entityName: 'Supplier', entityId: id),
      );
    }
  }

  @override
  Future<Result<void>> deleteSupplier(
    String id, {
    String? actorEmployeeId,
  }) async {
    try {
      final docRef = _collection.doc(id);
      final doc = await docRef.get();
      if (!doc.exists || doc.data() == null) {
        return Err<void>(
          NotFoundFailure(
            entityName: 'Supplier',
            entityId: id,
            message: 'Supplier $id was not found.',
          ),
        );
      }
      final existing = SupplierFirestoreDto.fromFirestore(doc);

      final referenced = await _firestore
          .collection(FirestoreCollections.stockIns)
          .where('supplier_id', isEqualTo: id)
          .limit(1)
          .get();

      if (referenced.docs.isNotEmpty) {
        return const Err<void>(
          ConflictFailure(
            message:
                'Cannot delete supplier with existing stock-in receipts. Archive instead.',
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
        entityType: AuditEntityType.supplier,
        entityId: id,
        description: 'Deleted supplier ${existing.fullName}.',
      );
      await batch.commit();
      return const Ok<void>(null);
    } catch (error) {
      return Err<void>(
        FirestoreHelpers.mapError(error, entityName: 'Supplier', entityId: id),
      );
    }
  }

  Future<void> _syncDenormalizedSupplierName(
    String supplierId,
    String newFullName,
  ) async {
    final snap = await _firestore
        .collection(FirestoreCollections.stockIns)
        .where('supplier_id', isEqualTo: supplierId)
        .get();
    final docs = snap.docs;
    for (var i = 0; i < docs.length; i += 400) {
      final batch = _firestore.batch();
      final end = (i + 400 < docs.length) ? i + 400 : docs.length;
      for (var j = i; j < end; j++) {
        batch.update(
          docs[j].reference,
          <String, dynamic>{'supplier_name': newFullName},
        );
      }
      await batch.commit();
    }
  }
}
