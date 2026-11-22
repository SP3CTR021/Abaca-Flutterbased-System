import 'package:cloud_firestore/cloud_firestore.dart' hide Order, ListEquality;

import '../../../../core/data/firestore/firestore_collections.dart';
import '../../../../core/data/firestore/firestore_helpers.dart';
import '../../../../core/data/input_validators.dart';
import '../../../../core/errors/app_failure.dart';
import '../../../../core/result/result.dart';
import '../../../../core/types/query_filters.dart';
import '../../../../core/utils/decimal_precision.dart';
import '../../../audit/data/firestore/firestore_audit_repository.dart';
import '../../../audit/domain/entities/audit_enums.dart';
import '../../domain/entities/inventory.dart';
import '../../domain/entities/stock_in.dart';
import '../../domain/entities/stock_in_item.dart';
import '../../domain/repositories/stock_in_repository.dart';
import 'inventory_firestore_dto.dart';
import 'stock_in_firestore_dto.dart';

/// Cloud Firestore implementation of [StockInRepository].
///
/// Models `stock_in_items` as subcollection `stock_ins/{stockinId}/items/{itemId}`
/// and updates `inventory/{inventoryId}.current_stock_kg` atomically inside
/// `FirebaseFirestore.runTransaction` (strict read-before-write order).
final class FirestoreStockInRepository implements StockInRepository {
  FirestoreStockInRepository(this._firestore);

  final FirebaseFirestore _firestore;

  CollectionReference<Map<String, dynamic>> get _stockIns =>
      _firestore.collection(FirestoreCollections.stockIns);

  @override
  Future<Result<StockInWithDetails>> createStockIn({
    String? orderId,
    required String supplierId,
    required String employeeId,
    required DateTime dateReceived,
    String? notes,
    required List<NewStockInItemInput> items,
  }) async {
    final errors = <String, String>{};
    InputValidators.requireNonEmpty(errors, 'supplierId', supplierId);
    InputValidators.requireNonEmpty(errors, 'employeeId', employeeId);
    if (items.isEmpty) {
      errors['items'] = 'At least one stock-in item is required.';
    } else {
      for (var i = 0; i < items.length; i++) {
        InputValidators.requireNonEmpty(
          errors,
          'items[$i].inventoryId',
          items[i].inventoryId,
        );
        InputValidators.requirePositive(
          errors,
          'items[$i].quantityKg',
          items[i].quantityKg,
        );
        InputValidators.requireNonNegative(
          errors,
          'items[$i].costPerKg',
          items[i].costPerKg,
        );
      }
    }
    final validation = InputValidators.toFailure(errors);
    if (validation != null) return Err<StockInWithDetails>(validation);

    try {
      final now = DateTime.now().toUtc();
      final dateNormalized =
          DateTime(dateReceived.year, dateReceived.month, dateReceived.day);
      final stockInRef = _stockIns.doc();
      final supplierRef =
          _firestore.collection(FirestoreCollections.suppliers).doc(supplierId);
      final employeeRef =
          _firestore.collection(FirestoreCollections.employees).doc(employeeId);
      final orderRef = orderId == null
          ? null
          : _firestore.collection(FirestoreCollections.orders).doc(orderId);
      final uniqueInvIds =
          items.map((item) => item.inventoryId).toSet().toList(growable: false);

      final result =
          await _firestore.runTransaction<StockInWithDetails>((tx) async {
        // 1. ALL READS FIRST
        final supplierSnap = await tx.get(supplierRef);
        if (!supplierSnap.exists || supplierSnap.data() == null) {
          throw NotFoundFailure(
            entityName: 'Supplier',
            entityId: supplierId,
            message: 'Supplier $supplierId was not found.',
          );
        }
        final employeeSnap = await tx.get(employeeRef);
        if (!employeeSnap.exists || employeeSnap.data() == null) {
          throw NotFoundFailure(
            entityName: 'Employee',
            entityId: employeeId,
            message: 'Employee $employeeId was not found.',
          );
        }
        if (orderRef != null) {
          final orderSnap = await tx.get(orderRef);
          if (!orderSnap.exists) {
            throw NotFoundFailure(
              entityName: 'Order',
              entityId: orderId!,
              message: 'Order $orderId was not found.',
            );
          }
        }

        final inventoryById = <String, Inventory>{};
        for (final invId in uniqueInvIds) {
          final invSnap = await tx.get(
            _firestore.collection(FirestoreCollections.inventory).doc(invId),
          );
          if (!invSnap.exists || invSnap.data() == null) {
            throw NotFoundFailure(
              entityName: 'Inventory',
              entityId: invId,
              message: 'Inventory grade $invId was not found.',
            );
          }
          inventoryById[invId] = InventoryFirestoreDto.fromFirestore(invSnap);
        }

        // Accumulate quantities per grade and construct domain line items.
        final qtyAddsByInvId = <String, double>{};
        final abacaTypeMap = <String, String>{};
        final createdItems = <StockInItem>[];
        final itemRefs = <DocumentReference<Map<String, dynamic>>>[];

        for (final input in items) {
          final qty = DecimalPrecision.round2(input.quantityKg);
          final cost = DecimalPrecision.round2(input.costPerKg);
          qtyAddsByInvId[input.inventoryId] = DecimalPrecision.add2(
            qtyAddsByInvId[input.inventoryId] ?? 0.0,
            qty,
          );
          abacaTypeMap[input.inventoryId] =
              inventoryById[input.inventoryId]!.abacaType;

          final itemRef = stockInRef
              .collection(FirestoreCollections.stockInItemsSubcollection)
              .doc();
          itemRefs.add(itemRef);
          createdItems.add(
            StockInItem(
              id: itemRef.id,
              stockInId: stockInRef.id,
              inventoryId: input.inventoryId,
              quantityKg: qty,
              costPerKg: cost,
              createdAt: now,
              updatedAt: now,
            ),
          );
        }

        final supplierData = supplierSnap.data()!;
        final employeeData = employeeSnap.data()!;
        final supplierName = FirestoreHelpers.formatFullName(
          firstName: supplierData['first_name'] as String,
          middleName: supplierData['middle_name'] as String?,
          lastName: supplierData['last_name'] as String,
        );
        final employeeName = FirestoreHelpers.formatFullName(
          firstName: employeeData['first_name'] as String,
          middleName: employeeData['middle_name'] as String?,
          lastName: employeeData['last_name'] as String,
        );
        final totalCost =
            DecimalPrecision.sum2(createdItems.map((i) => i.totalCost));

        // 2. ALL WRITES AFTER READS
        tx.set(
          stockInRef,
          StockInFirestoreDto.headerToFirestore(
            orderId: orderId,
            supplierId: supplierId,
            employeeId: employeeId,
            dateReceived: dateNormalized,
            notes: notes,
            supplierName: supplierName,
            employeeName: employeeName,
            inventoryIds: uniqueInvIds,
            abacaTypeByInventoryId: abacaTypeMap,
            totalCost: totalCost,
            createdAt: now,
            updatedAt: now,
          ),
        );

        for (var i = 0; i < createdItems.length; i++) {
          final item = createdItems[i];
          tx.set(
            itemRefs[i],
            StockInFirestoreDto.itemToFirestore(
              stockInId: stockInRef.id,
              inventoryId: item.inventoryId,
              abacaType: abacaTypeMap[item.inventoryId]!,
              quantityKg: item.quantityKg,
              costPerKg: item.costPerKg,
              dateReceived: dateNormalized,
              createdAt: now,
              updatedAt: now,
            ),
          );
        }

        for (final entry in qtyAddsByInvId.entries) {
          final inv = inventoryById[entry.key]!;
          final nextStock =
              DecimalPrecision.add2(inv.currentStockKg, entry.value);
          tx.update(
            _firestore.collection(FirestoreCollections.inventory).doc(entry.key),
            <String, dynamic>{
              'current_stock_kg': nextStock,
              'last_updated': FirestoreHelpers.toTimestamp(now),
            },
          );
        }

        FirestoreAuditRepository.setAuditInTransaction(
          tx,
          _firestore,
          actorEmployeeId: employeeId,
          action: AuditAction.created,
          entityType: AuditEntityType.stockIn,
          entityId: stockInRef.id,
          description:
              'Recorded stock-in receipt with ${createdItems.length} item(s).',
          timestamp: now,
        );

        return StockInWithDetails(
          stockIn: StockIn(
            id: stockInRef.id,
            orderId: orderId,
            supplierId: supplierId,
            employeeId: employeeId,
            dateReceived: dateNormalized,
            notes: notes?.trim().isEmpty == true ? null : notes?.trim(),
            createdAt: now,
            updatedAt: now,
          ),
          items: createdItems,
          supplierName: supplierName,
          employeeName: employeeName,
          abacaTypeByInventoryId: abacaTypeMap,
        );
      });

      return Ok<StockInWithDetails>(result);
    } catch (error) {
      return Err<StockInWithDetails>(
        FirestoreHelpers.mapError(error, entityName: 'StockIn'),
      );
    }
  }

  @override
  Future<Result<StockInWithDetails>> getStockInWithItems(String id) async {
    try {
      final headerRef = _stockIns.doc(id);
      final headerSnap = await headerRef.get();
      if (!headerSnap.exists || headerSnap.data() == null) {
        return Err<StockInWithDetails>(
          NotFoundFailure(
            entityName: 'StockIn',
            entityId: id,
            message: 'Stock-in receipt $id was not found.',
          ),
        );
      }

      final itemsSnap = await headerRef
          .collection(FirestoreCollections.stockInItemsSubcollection)
          .get();

      return Ok<StockInWithDetails>(
        StockInFirestoreDto.detailsFromFirestore(
          headerDoc: headerSnap,
          itemDocs: itemsSnap.docs,
        ),
      );
    } catch (error) {
      return Err<StockInWithDetails>(
        FirestoreHelpers.mapError(error, entityName: 'StockIn', entityId: id),
      );
    }
  }

  @override
  Future<Result<List<StockInWithDetails>>> getStockIns({
    String? supplierId,
    String? orderId,
    String? inventoryId,
    DateRangeFilter? dateRange,
  }) async {
    final rangeFailure = InputValidators.validateDateRange(dateRange);
    if (rangeFailure != null) return Err<List<StockInWithDetails>>(rangeFailure);

    try {
      Query<Map<String, dynamic>> query = _stockIns;
      if (supplierId != null) {
        query = query.where('supplier_id', isEqualTo: supplierId);
      } else if (orderId != null) {
        query = query.where('order_id', isEqualTo: orderId);
      } else if (inventoryId != null) {
        query = query.where('inventory_ids', arrayContains: inventoryId);
      }

      final headersSnap =
          await query.orderBy('date_received', descending: true).get();

      final results = <StockInWithDetails>[];
      for (final headerDoc in headersSnap.docs) {
        final data = headerDoc.data();
        if (supplierId != null &&
            orderId != null &&
            data['order_id'] != orderId) {
          continue;
        }
        if (inventoryId != null) {
          final invIds =
              (data['inventory_ids'] as List<dynamic>? ?? const <dynamic>[])
                  .cast<String>();
          if (!invIds.contains(inventoryId)) continue;
        }

        final headerDate =
            FirestoreHelpers.fromDateOnlyTimestamp(data['date_received']);
        if (dateRange != null && !dateRange.contains(headerDate)) {
          continue;
        }

        final itemsSnap = await headerDoc.reference
            .collection(FirestoreCollections.stockInItemsSubcollection)
            .get();
        results.add(
          StockInFirestoreDto.detailsFromFirestore(
            headerDoc: headerDoc,
            itemDocs: itemsSnap.docs,
          ),
        );
      }

      return Ok<List<StockInWithDetails>>(
        List<StockInWithDetails>.unmodifiable(results),
      );
    } catch (error) {
      return Err<List<StockInWithDetails>>(
        FirestoreHelpers.mapError(error, entityName: 'StockIn'),
      );
    }
  }

  @override
  Stream<List<StockInWithDetails>> watchStockIns({
    String? supplierId,
    String? orderId,
  }) {
    Query<Map<String, dynamic>> query = _stockIns;
    if (supplierId != null) {
      query = query.where('supplier_id', isEqualTo: supplierId);
    } else if (orderId != null) {
      query = query.where('order_id', isEqualTo: orderId);
    }

    return query
        .orderBy('date_received', descending: true)
        .snapshots()
        .asyncMap((snapshot) async {
      final list = <StockInWithDetails>[];
      for (final headerDoc in snapshot.docs) {
        if (supplierId != null &&
            orderId != null &&
            headerDoc.data()['order_id'] != orderId) {
          continue;
        }
        final itemsSnap = await headerDoc.reference
            .collection(FirestoreCollections.stockInItemsSubcollection)
            .get();
        list.add(
          StockInFirestoreDto.detailsFromFirestore(
            headerDoc: headerDoc,
            itemDocs: itemsSnap.docs,
          ),
        );
      }
      return List<StockInWithDetails>.unmodifiable(list);
    });
  }

  @override
  Future<Result<void>> deleteStockIn(
    String id, {
    String? actorEmployeeId,
  }) async {
    try {
      final headerRef = _stockIns.doc(id);
      // Pre-fetch item doc references since runTransaction cannot run queries.
      final preItemsSnap = await headerRef
          .collection(FirestoreCollections.stockInItemsSubcollection)
          .get();
      final itemRefs =
          preItemsSnap.docs.map((d) => d.reference).toList(growable: false);

      final now = DateTime.now().toUtc();
      await _firestore.runTransaction<void>((tx) async {
        // 1. ALL READS FIRST
        final headerSnap = await tx.get(headerRef);
        if (!headerSnap.exists || headerSnap.data() == null) {
          throw NotFoundFailure(
            entityName: 'StockIn',
            entityId: id,
            message: 'Stock-in receipt $id was not found.',
          );
        }

        final reversalsByInvId = <String, double>{};
        final liveItemRefs = <DocumentReference<Map<String, dynamic>>>[];
        for (final itemRef in itemRefs) {
          final itemSnap = await tx.get(itemRef);
          if (!itemSnap.exists || itemSnap.data() == null) continue;
          liveItemRefs.add(itemRef);
          final item = StockInFirestoreDto.itemFromFirestore(
            itemSnap,
            stockInId: id,
          );
          reversalsByInvId[item.inventoryId] = DecimalPrecision.add2(
            reversalsByInvId[item.inventoryId] ?? 0.0,
            item.quantityKg,
          );
        }

        final invById = <String, Inventory>{};
        for (final invId in reversalsByInvId.keys) {
          final invSnap = await tx.get(
            _firestore.collection(FirestoreCollections.inventory).doc(invId),
          );
          if (!invSnap.exists || invSnap.data() == null) {
            throw NotFoundFailure(
              entityName: 'Inventory',
              entityId: invId,
              message: 'Inventory grade $invId was not found.',
            );
          }
          invById[invId] = InventoryFirestoreDto.fromFirestore(invSnap);
        }

        // Validate reversal won't drive any grade negative before writing.
        for (final entry in reversalsByInvId.entries) {
          final inv = invById[entry.key]!;
          if (DecimalPrecision.compare2(inv.currentStockKg, entry.value) < 0) {
            throw InsufficientStockFailure(
              abacaType: inv.abacaType,
              availableKg: inv.currentStockKg,
              requestedKg: entry.value,
              message:
                  'Cannot reverse stock-in: insufficient ${inv.abacaType} stock.',
            );
          }
        }

        // 2. ALL WRITES AFTER READS
        for (final entry in reversalsByInvId.entries) {
          final inv = invById[entry.key]!;
          final nextStock =
              DecimalPrecision.subtract2(inv.currentStockKg, entry.value);
          tx.update(
            _firestore.collection(FirestoreCollections.inventory).doc(entry.key),
            <String, dynamic>{
              'current_stock_kg': nextStock,
              'last_updated': FirestoreHelpers.toTimestamp(now),
            },
          );
        }

        for (final itemRef in liveItemRefs) {
          tx.delete(itemRef);
        }
        tx.delete(headerRef);

        FirestoreAuditRepository.setAuditInTransaction(
          tx,
          _firestore,
          actorEmployeeId: actorEmployeeId,
          action: AuditAction.deleted,
          entityType: AuditEntityType.stockIn,
          entityId: id,
          description:
              'Deleted stock-in receipt and reversed inbound stock quantities.',
          timestamp: now,
        );
      });

      return const Ok<void>(null);
    } catch (error) {
      return Err<void>(
        FirestoreHelpers.mapError(error, entityName: 'StockIn', entityId: id),
      );
    }
  }
}
