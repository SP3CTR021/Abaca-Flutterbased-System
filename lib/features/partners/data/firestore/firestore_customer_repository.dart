import 'package:cloud_firestore/cloud_firestore.dart' hide Order, ListEquality;

import '../../../../core/data/firestore/firestore_collections.dart';
import '../../../../core/data/firestore/firestore_helpers.dart';
import '../../../../core/data/input_validators.dart';
import '../../../../core/errors/app_failure.dart';
import '../../../../core/result/result.dart';
import '../../../audit/data/firestore/firestore_audit_repository.dart';
import '../../../audit/domain/entities/audit_enums.dart';
import '../../domain/entities/customer.dart';
import '../../domain/repositories/customer_repository.dart';
import 'customer_firestore_dto.dart';

/// Cloud Firestore implementation of [CustomerRepository].
///
/// Workarounds:
/// - `search_tokens` array enables partial-name search (`arrayContains`).
/// - `updateCustomer` syncs denormalized `customer_name` onto `orders` when changed.
/// - `deleteCustomer` checks `orders` before deleting (`ON DELETE RESTRICT`).
final class FirestoreCustomerRepository implements CustomerRepository {
  FirestoreCustomerRepository(this._firestore);

  final FirebaseFirestore _firestore;

  CollectionReference<Map<String, dynamic>> get _collection =>
      _firestore.collection(FirestoreCollections.customers);

  @override
  Future<Result<Customer>> createCustomer({
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
    if (validation != null) return Err<Customer>(validation);

    try {
      final docRef = _collection.doc();
      final now = DateTime.now().toUtc();
      final created = Customer(
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
        CustomerFirestoreDto.toFirestore(
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
        entityType: AuditEntityType.customer,
        entityId: created.id,
        description: 'Created customer ${created.fullName}.',
        timestamp: now,
      );
      await batch.commit();

      return Ok<Customer>(created);
    } catch (error) {
      return Err<Customer>(
        FirestoreHelpers.mapError(error, entityName: 'Customer'),
      );
    }
  }

  @override
  Future<Result<Customer>> getCustomerById(String id) async {
    try {
      final doc = await _collection.doc(id).get();
      if (!doc.exists || doc.data() == null) {
        return Err<Customer>(
          NotFoundFailure(
            entityName: 'Customer',
            entityId: id,
            message: 'Customer $id was not found.',
          ),
        );
      }
      return Ok<Customer>(CustomerFirestoreDto.fromFirestore(doc));
    } catch (error) {
      return Err<Customer>(
        FirestoreHelpers.mapError(error, entityName: 'Customer', entityId: id),
      );
    }
  }

  @override
  Future<Result<List<Customer>>> getCustomers({
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
      var list = snapshot.docs.map(CustomerFirestoreDto.fromFirestore).toList();

      if (trimmedQuery.isNotEmpty) {
        list = list.where((customer) {
          return customer.fullName.toLowerCase().contains(trimmedQuery) ||
              (customer.contactNumber?.toLowerCase().contains(trimmedQuery) ??
                  false) ||
              (customer.address?.toLowerCase().contains(trimmedQuery) ?? false);
        }).toList();
      }

      list.sort((a, b) {
        final lastCmp = a.lastName.compareTo(b.lastName);
        return lastCmp != 0 ? lastCmp : a.firstName.compareTo(b.firstName);
      });
      return Ok<List<Customer>>(List<Customer>.unmodifiable(list));
    } catch (error) {
      return Err<List<Customer>>(
        FirestoreHelpers.mapError(error, entityName: 'Customer'),
      );
    }
  }

  @override
  Stream<List<Customer>> watchCustomers({bool? isActive}) {
    Query<Map<String, dynamic>> query = _collection;
    if (isActive != null) {
      query = query.where('is_active', isEqualTo: isActive);
    }
    return query.orderBy('last_name', descending: false).snapshots().map(
          (snapshot) => snapshot.docs
              .map(CustomerFirestoreDto.fromFirestore)
              .toList(growable: false),
        );
  }

  @override
  Future<Result<Customer>> updateCustomer(
    Customer customer, {
    String? actorEmployeeId,
  }) async {
    final errors = <String, String>{};
    InputValidators.requireNonEmpty(errors, 'firstName', customer.firstName);
    InputValidators.requireNonEmpty(errors, 'lastName', customer.lastName);
    InputValidators.validateMaxLength(
      errors,
      'address',
      customer.address,
      500,
    );
    final validation = InputValidators.toFailure(errors);
    if (validation != null) return Err<Customer>(validation);

    try {
      final docRef = _collection.doc(customer.id);
      final now = DateTime.now().toUtc();
      String? previousFullName;

      final updated = await _firestore.runTransaction<Customer>((tx) async {
        final snapshot = await tx.get(docRef);
        if (!snapshot.exists || snapshot.data() == null) {
          throw NotFoundFailure(
            entityName: 'Customer',
            entityId: customer.id,
            message: 'Customer ${customer.id} was not found.',
          );
        }
        final previous = CustomerFirestoreDto.fromFirestore(snapshot);
        previousFullName = previous.fullName;

        final next = customer.copyWith(
          createdAt: previous.createdAt,
          updatedAt: now,
        );

        tx.update(
          docRef,
          CustomerFirestoreDto.toFirestore(
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
          entityType: AuditEntityType.customer,
          entityId: next.id,
          description: 'Updated customer ${next.fullName}.',
          timestamp: now,
        );

        return next;
      });

      if (previousFullName != null && previousFullName != updated.fullName) {
        await _syncDenormalizedCustomerName(updated.id, updated.fullName);
      }

      return Ok<Customer>(updated);
    } catch (error) {
      return Err<Customer>(
        FirestoreHelpers.mapError(
          error,
          entityName: 'Customer',
          entityId: customer.id,
        ),
      );
    }
  }

  @override
  Future<Result<Customer>> setCustomerActive({
    required String id,
    required bool isActive,
    String? actorEmployeeId,
  }) async {
    try {
      final docRef = _collection.doc(id);
      final now = DateTime.now().toUtc();

      final updated = await _firestore.runTransaction<Customer>((tx) async {
        final snapshot = await tx.get(docRef);
        if (!snapshot.exists || snapshot.data() == null) {
          throw NotFoundFailure(
            entityName: 'Customer',
            entityId: id,
            message: 'Customer $id was not found.',
          );
        }
        final existing = CustomerFirestoreDto.fromFirestore(snapshot);
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
          entityType: AuditEntityType.customer,
          entityId: id,
          description: isActive
              ? 'Restored customer ${next.fullName}.'
              : 'Archived customer ${next.fullName}.',
          timestamp: now,
        );
        return next;
      });

      return Ok<Customer>(updated);
    } catch (error) {
      return Err<Customer>(
        FirestoreHelpers.mapError(error, entityName: 'Customer', entityId: id),
      );
    }
  }

  @override
  Future<Result<void>> deleteCustomer(
    String id, {
    String? actorEmployeeId,
  }) async {
    try {
      final docRef = _collection.doc(id);
      final doc = await docRef.get();
      if (!doc.exists || doc.data() == null) {
        return Err<void>(
          NotFoundFailure(
            entityName: 'Customer',
            entityId: id,
            message: 'Customer $id was not found.',
          ),
        );
      }
      final existing = CustomerFirestoreDto.fromFirestore(doc);

      final referenced = await _firestore
          .collection(FirestoreCollections.orders)
          .where('customer_id', isEqualTo: id)
          .limit(1)
          .get();

      if (referenced.docs.isNotEmpty) {
        return const Err<void>(
          ConflictFailure(
            message:
                'Cannot delete customer with existing orders. Archive instead.',
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
        entityType: AuditEntityType.customer,
        entityId: id,
        description: 'Deleted customer ${existing.fullName}.',
      );
      await batch.commit();
      return const Ok<void>(null);
    } catch (error) {
      return Err<void>(
        FirestoreHelpers.mapError(error, entityName: 'Customer', entityId: id),
      );
    }
  }

  Future<void> _syncDenormalizedCustomerName(
    String customerId,
    String newFullName,
  ) async {
    final snap = await _firestore
        .collection(FirestoreCollections.orders)
        .where('customer_id', isEqualTo: customerId)
        .get();
    final docs = snap.docs;
    for (var i = 0; i < docs.length; i += 400) {
      final batch = _firestore.batch();
      final end = (i + 400 < docs.length) ? i + 400 : docs.length;
      for (var j = i; j < end; j++) {
        batch.update(
          docs[j].reference,
          <String, dynamic>{'customer_name': newFullName},
        );
      }
      await batch.commit();
    }
  }
}
