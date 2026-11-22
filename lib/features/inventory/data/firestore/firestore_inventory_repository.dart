import 'package:cloud_firestore/cloud_firestore.dart' hide Order, ListEquality;

import '../../../../core/data/firestore/firestore_collections.dart';
import '../../../../core/data/firestore/firestore_helpers.dart';
import '../../../../core/data/input_validators.dart';
import '../../../../core/errors/app_failure.dart';
import '../../../../core/result/result.dart';
import '../../../../core/utils/decimal_precision.dart';
import '../../../audit/data/firestore/firestore_audit_repository.dart';
import '../../../audit/domain/entities/audit_enums.dart';
import '../../domain/entities/inventory.dart';
import '../../domain/repositories/inventory_repository.dart';
import 'inventory_firestore_dto.dart';

/// Cloud Firestore implementation of [InventoryRepository].
///
/// Workarounds:
/// - `inventory_type_locks/{normalizedKey}` guarantees case-insensitive uniqueness
///   of `abaca_type` atomically inside `runTransaction`.
/// - `updateGradeMetadata` swaps lock docs in-transaction and cascades
///   `abaca_type` renames to `orders`, `stock_outs`, and `items`.
/// - `deleteGrade` verifies zero references (`ON DELETE RESTRICT`).
final class FirestoreInventoryRepository implements InventoryRepository {
  FirestoreInventoryRepository(this._firestore);

  final FirebaseFirestore _firestore;

  CollectionReference<Map<String, dynamic>> get _collection =>
      _firestore.collection(FirestoreCollections.inventory);

  CollectionReference<Map<String, dynamic>> get _locks =>
      _firestore.collection(FirestoreCollections.inventoryTypeLocks);

  @override
  Future<Result<Inventory>> createGrade({
    required String abacaType,
    String? description,
    double initialStockKg = 0.0,
    double minStockThresholdKg = 0.0,
    String? actorEmployeeId,
  }) async {
    final errors = <String, String>{};
    InputValidators.requireNonEmpty(errors, 'abacaType', abacaType);
    InputValidators.validateMaxLength(
      errors,
      'description',
      description,
      500,
    );
    InputValidators.requireNonNegative(
      errors,
      'initialStockKg',
      initialStockKg,
    );
    InputValidators.requireNonNegative(
      errors,
      'minStockThresholdKg',
      minStockThresholdKg,
    );
    final validation = InputValidators.toFailure(errors);
    if (validation != null) return Err<Inventory>(validation);

    try {
      final trimmedType = abacaType.trim();
      final lockKey = FirestoreCollections.normalizeLockKey(trimmedType);
      final lockRef = _locks.doc(lockKey);
      final invRef = _collection.doc();
      final now = DateTime.now().toUtc();

      final created = await _firestore.runTransaction<Inventory>((tx) async {
        final lockSnap = await tx.get(lockRef);
        if (lockSnap.exists) {
          throw ConflictFailure(
            message: 'Abaca grade "$trimmedType" already exists.',
            code: 'unique_violation',
          );
        }

        final entity = Inventory(
          id: invRef.id,
          abacaType: trimmedType,
          description: description?.trim().isEmpty == true
              ? null
              : description?.trim(),
          currentStockKg: DecimalPrecision.round2(initialStockKg),
          minStockThresholdKg: DecimalPrecision.round2(minStockThresholdKg),
          isActive: true,
          createdAt: now,
          lastUpdated: now,
        );

        tx.set(lockRef, <String, dynamic>{
          'inventory_id': entity.id,
          'abaca_type': entity.abacaType,
        });
        tx.set(
          invRef,
          InventoryFirestoreDto.toFirestore(
            abacaType: entity.abacaType,
            description: entity.description,
            currentStockKg: entity.currentStockKg,
            minStockThresholdKg: entity.minStockThresholdKg,
            isActive: entity.isActive,
            createdAt: now,
            lastUpdated: now,
          ),
        );

        FirestoreAuditRepository.setAuditInTransaction(
          tx,
          _firestore,
          actorEmployeeId: actorEmployeeId,
          action: AuditAction.created,
          entityType: AuditEntityType.inventory,
          entityId: entity.id,
          description: 'Created inventory grade ${entity.abacaType}.',
          newValues: <String, Object?>{
            'abaca_type': entity.abacaType,
            'current_stock_kg': entity.currentStockKg,
            'min_stock_threshold_kg': entity.minStockThresholdKg,
          },
          timestamp: now,
        );

        return entity;
      });

      return Ok<Inventory>(created);
    } catch (error) {
      return Err<Inventory>(
        FirestoreHelpers.mapError(error, entityName: 'Inventory'),
      );
    }
  }

  @override
  Future<Result<Inventory>> getInventoryById(String id) async {
    try {
      final doc = await _collection.doc(id).get();
      if (!doc.exists || doc.data() == null) {
        return Err<Inventory>(
          NotFoundFailure(
            entityName: 'Inventory',
            entityId: id,
            message: 'Inventory grade $id was not found.',
          ),
        );
      }
      return Ok<Inventory>(InventoryFirestoreDto.fromFirestore(doc));
    } catch (error) {
      return Err<Inventory>(
        FirestoreHelpers.mapError(error, entityName: 'Inventory', entityId: id),
      );
    }
  }

  @override
  Future<Result<Inventory>> getInventoryByAbacaType(String abacaType) async {
    final trimmed = abacaType.trim();
    if (trimmed.isEmpty) {
      return Err<Inventory>(
        ValidationFailure(
          message: 'Abaca type is required.',
          fieldErrors: const <String, String>{
            'abacaType': 'abacaType is required.',
          },
        ),
      );
    }

    try {
      final lockDoc =
          await _locks.doc(FirestoreCollections.normalizeLockKey(trimmed)).get();
      final lockData = lockDoc.data();
      if (lockDoc.exists && lockData != null) {
        final inventoryId = lockData['inventory_id'] as String?;
        if (inventoryId != null) {
          return await getInventoryById(inventoryId);
        }
      }

      final fallback = await _collection
          .where('abaca_type_lower', isEqualTo: trimmed.toLowerCase())
          .limit(1)
          .get();
      if (fallback.docs.isEmpty) {
        return Err<Inventory>(
          NotFoundFailure(
            entityName: 'Inventory',
            entityId: trimmed,
            message: 'Inventory grade "$trimmed" was not found.',
          ),
        );
      }
      return Ok<Inventory>(
        InventoryFirestoreDto.fromFirestore(fallback.docs.first),
      );
    } catch (error) {
      return Err<Inventory>(
        FirestoreHelpers.mapError(
          error,
          entityName: 'Inventory',
          entityId: trimmed,
        ),
      );
    }
  }

  @override
  Future<Result<List<Inventory>>> getAllInventory({
    bool? isActive,
    bool onlyLowStock = false,
  }) async {
    try {
      Query<Map<String, dynamic>> query = _collection;
      if (isActive != null) {
        query = query.where('is_active', isEqualTo: isActive);
      }
      final snapshot = await query.orderBy('abaca_type', descending: false).get();

      var items = snapshot.docs.map(InventoryFirestoreDto.fromFirestore).toList();
      if (onlyLowStock) {
        items = items.where((item) => item.isLowStock).toList();
      }
      return Ok<List<Inventory>>(List<Inventory>.unmodifiable(items));
    } catch (error) {
      return Err<List<Inventory>>(
        FirestoreHelpers.mapError(error, entityName: 'Inventory'),
      );
    }
  }

  @override
  Stream<List<Inventory>> watchInventory({
    bool? isActive,
    bool onlyLowStock = false,
  }) {
    Query<Map<String, dynamic>> query = _collection;
    if (isActive != null) {
      query = query.where('is_active', isEqualTo: isActive);
    }
    return query.orderBy('abaca_type', descending: false).snapshots().map(
      (snapshot) {
        var items = snapshot.docs.map(InventoryFirestoreDto.fromFirestore);
        if (onlyLowStock) {
          items = items.where((item) => item.isLowStock);
        }
        return items.toList(growable: false);
      },
    );
  }

  @override
  Future<Result<Inventory>> updateGradeMetadata({
    required String id,
    String? abacaType,
    String? description,
    bool clearDescription = false,
    double? minStockThresholdKg,
    bool? isActive,
    String? actorEmployeeId,
  }) async {
    final errors = <String, String>{};
    if (abacaType != null) {
      InputValidators.requireNonEmpty(errors, 'abacaType', abacaType);
    }
    InputValidators.validateMaxLength(
      errors,
      'description',
      description,
      500,
    );
    if (minStockThresholdKg != null) {
      InputValidators.requireNonNegative(
        errors,
        'minStockThresholdKg',
        minStockThresholdKg,
      );
    }
    final validation = InputValidators.toFailure(errors);
    if (validation != null) return Err<Inventory>(validation);

    try {
      final invRef = _collection.doc(id);
      final now = DateTime.now().toUtc();
      String? renamedFrom;
      String? renamedTo;

      final updated = await _firestore.runTransaction<Inventory>((tx) async {
        final snapshot = await tx.get(invRef);
        if (!snapshot.exists || snapshot.data() == null) {
          throw NotFoundFailure(
            entityName: 'Inventory',
            entityId: id,
            message: 'Inventory grade $id was not found.',
          );
        }
        final existing = InventoryFirestoreDto.fromFirestore(snapshot);
        final nextType = abacaType?.trim() ?? existing.abacaType;

        final oldLockKey =
            FirestoreCollections.normalizeLockKey(existing.abacaType);
        final newLockKey = FirestoreCollections.normalizeLockKey(nextType);
        final oldLockRef = _locks.doc(oldLockKey);
        final newLockRef = _locks.doc(newLockKey);

        // Read new lock before any writes when grade label changes.
        if (newLockKey != oldLockKey) {
          final newLockSnap = await tx.get(newLockRef);
          if (newLockSnap.exists &&
              newLockSnap.data()?['inventory_id'] != id) {
            throw ConflictFailure(
              message: 'Abaca grade "$nextType" already exists.',
              code: 'unique_violation',
            );
          }
        }

        final nextDesc = clearDescription
            ? null
            : (description != null
                ? (description.trim().isEmpty ? null : description.trim())
                : existing.description);

        final nextEntity = existing.copyWith(
          abacaType: nextType,
          description: nextDesc,
          clearDescription: nextDesc == null,
          minStockThresholdKg: minStockThresholdKg != null
              ? DecimalPrecision.round2(minStockThresholdKg)
              : existing.minStockThresholdKg,
          isActive: isActive ?? existing.isActive,
          lastUpdated: now,
        );

        if (newLockKey != oldLockKey) {
          tx.delete(oldLockRef);
          tx.set(newLockRef, <String, dynamic>{
            'inventory_id': id,
            'abaca_type': nextEntity.abacaType,
          });
        } else if (nextEntity.abacaType != existing.abacaType) {
          tx.set(newLockRef, <String, dynamic>{
            'inventory_id': id,
            'abaca_type': nextEntity.abacaType,
          });
        }

        tx.update(
          invRef,
          InventoryFirestoreDto.toFirestore(
            abacaType: nextEntity.abacaType,
            description: nextEntity.description,
            currentStockKg: existing.currentStockKg,
            minStockThresholdKg: nextEntity.minStockThresholdKg,
            isActive: nextEntity.isActive,
            createdAt: existing.createdAt,
            lastUpdated: now,
          ),
        );

        if (existing.abacaType != nextEntity.abacaType) {
          renamedFrom = existing.abacaType;
          renamedTo = nextEntity.abacaType;
        }

        FirestoreAuditRepository.setAuditInTransaction(
          tx,
          _firestore,
          actorEmployeeId: actorEmployeeId,
          action: AuditAction.updated,
          entityType: AuditEntityType.inventory,
          entityId: id,
          description: 'Updated inventory grade ${nextEntity.abacaType}.',
          timestamp: now,
        );

        return nextEntity;
      });

      if (renamedFrom != null && renamedTo != null) {
        await _cascadeAbacaTypeRename(id, renamedTo!);
      }

      return Ok<Inventory>(updated);
    } catch (error) {
      return Err<Inventory>(
        FirestoreHelpers.mapError(error, entityName: 'Inventory', entityId: id),
      );
    }
  }

  @override
  Future<Result<void>> deleteGrade(
    String id, {
    String? actorEmployeeId,
  }) async {
    try {
      final docRef = _collection.doc(id);
      final doc = await docRef.get();
      if (!doc.exists || doc.data() == null) {
        return Err<void>(
          NotFoundFailure(
            entityName: 'Inventory',
            entityId: id,
            message: 'Inventory grade $id was not found.',
          ),
        );
      }
      final existing = InventoryFirestoreDto.fromFirestore(doc);

      final checks = await Future.wait<QuerySnapshot<Map<String, dynamic>>>([
        _firestore
            .collection(FirestoreCollections.orders)
            .where('inventory_id', isEqualTo: id)
            .limit(1)
            .get(),
        _firestore
            .collection(FirestoreCollections.stockOuts)
            .where('inventory_id', isEqualTo: id)
            .limit(1)
            .get(),
        _firestore
            .collectionGroup(FirestoreCollections.stockInItemsSubcollection)
            .where('inventory_id', isEqualTo: id)
            .limit(1)
            .get(),
      ]);

      if (checks.any((snap) => snap.docs.isNotEmpty)) {
        return const Err<void>(
          ConflictFailure(
            message:
                'Cannot delete abaca grade referenced by orders or stock history. Archive instead.',
            code: 'foreign_key_violation',
          ),
        );
      }

      final lockRef =
          _locks.doc(FirestoreCollections.normalizeLockKey(existing.abacaType));
      final batch = _firestore.batch();
      batch.delete(docRef);
      batch.delete(lockRef);
      FirestoreAuditRepository.setAuditInBatch(
        batch,
        _firestore,
        actorEmployeeId: actorEmployeeId,
        action: AuditAction.deleted,
        entityType: AuditEntityType.inventory,
        entityId: id,
        description: 'Deleted inventory grade ${existing.abacaType}.',
      );
      await batch.commit();
      return const Ok<void>(null);
    } catch (error) {
      return Err<void>(
        FirestoreHelpers.mapError(error, entityName: 'Inventory', entityId: id),
      );
    }
  }

  Future<void> _cascadeAbacaTypeRename(
    String inventoryId,
    String newAbacaType,
  ) async {
    final refs = <DocumentReference<Map<String, dynamic>>>[];

    final ordersSnap = await _firestore
        .collection(FirestoreCollections.orders)
        .where('inventory_id', isEqualTo: inventoryId)
        .get();
    for (final doc in ordersSnap.docs) {
      refs.add(doc.reference);
    }

    final stockOutsSnap = await _firestore
        .collection(FirestoreCollections.stockOuts)
        .where('inventory_id', isEqualTo: inventoryId)
        .get();
    for (final doc in stockOutsSnap.docs) {
      refs.add(doc.reference);
    }

    final itemsSnap = await _firestore
        .collectionGroup(FirestoreCollections.stockInItemsSubcollection)
        .where('inventory_id', isEqualTo: inventoryId)
        .get();
    for (final doc in itemsSnap.docs) {
      refs.add(doc.reference);
    }

    for (var i = 0; i < refs.length; i += 400) {
      final batch = _firestore.batch();
      final end = (i + 400 < refs.length) ? i + 400 : refs.length;
      for (var j = i; j < end; j++) {
        batch.update(refs[j], <String, dynamic>{'abaca_type': newAbacaType});
      }
      await batch.commit();
    }
  }
}
