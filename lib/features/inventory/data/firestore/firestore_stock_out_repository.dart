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
import '../../domain/entities/stock_out.dart';
import '../../domain/entities/stock_out_reason.dart';
import '../../domain/repositories/stock_out_repository.dart';
import 'inventory_firestore_dto.dart';
import 'stock_out_firestore_dto.dart';

/// Cloud Firestore implementation of [StockOutRepository].
final class FirestoreStockOutRepository implements StockOutRepository {
  FirestoreStockOutRepository(this._firestore);

  final FirebaseFirestore _firestore;

  CollectionReference<Map<String, dynamic>> get _stockOuts =>
      _firestore.collection(FirestoreCollections.stockOuts);

  @override
  Future<Result<StockOut>> createStockOut({
    required String inventoryId,
    required String employeeId,
    required double quantityKg,
    required StockOutReason reason,
    String? notes,
    required DateTime date,
  }) async {
    if (reason == StockOutReason.released) {
      return const Err<StockOut>(
        InvalidStateTransitionFailure(
          entityName: 'StockOut',
          currentState: 'manual',
          attemptedAction: 'create_released_stock_out',
          message:
              'Released stock-outs must be created via DeliveryRepository.completeDelivery.',
        ),
      );
    }

    final errors = <String, String>{};
    InputValidators.requireNonEmpty(errors, 'inventoryId', inventoryId);
    InputValidators.requireNonEmpty(errors, 'employeeId', employeeId);
    InputValidators.requirePositive(errors, 'quantityKg', quantityKg);
    final validation = InputValidators.toFailure(errors);
    if (validation != null) return Err<StockOut>(validation);

    try {
      final now = DateTime.now().toUtc();
      final dateOnly = DateTime(date.year, date.month, date.day);
      final qty = DecimalPrecision.round2(quantityKg);
      final invRef =
          _firestore.collection(FirestoreCollections.inventory).doc(inventoryId);
      final empRef =
          _firestore.collection(FirestoreCollections.employees).doc(employeeId);
      final outRef = _stockOuts.doc();

      final created = await _firestore.runTransaction<StockOut>((tx) async {
        // 1. ALL READS FIRST
        final invSnap = await tx.get(invRef);
        if (!invSnap.exists || invSnap.data() == null) {
          throw NotFoundFailure(
            entityName: 'Inventory',
            entityId: inventoryId,
            message: 'Inventory grade $inventoryId was not found.',
          );
        }
        final empSnap = await tx.get(empRef);
        if (!empSnap.exists || empSnap.data() == null) {
          throw NotFoundFailure(
            entityName: 'Employee',
            entityId: employeeId,
            message: 'Employee $employeeId was not found.',
          );
        }

        final inv = InventoryFirestoreDto.fromFirestore(invSnap);
        if (DecimalPrecision.compare2(inv.currentStockKg, qty) < 0) {
          throw InsufficientStockFailure(
            abacaType: inv.abacaType,
            availableKg: inv.currentStockKg,
            requestedKg: qty,
            message: 'Insufficient ${inv.abacaType} stock for stock-out.',
          );
        }

        final empData = empSnap.data()!;
        final empName = FirestoreHelpers.formatFullName(
          firstName: empData['first_name'] as String,
          middleName: empData['middle_name'] as String?,
          lastName: empData['last_name'] as String,
        );

        // 2. ALL WRITES AFTER READS
        tx.update(invRef, <String, dynamic>{
          'current_stock_kg': DecimalPrecision.subtract2(inv.currentStockKg, qty),
          'last_updated': FirestoreHelpers.toTimestamp(now),
        });

        tx.set(
          outRef,
          StockOutFirestoreDto.toFirestore(
            inventoryId: inventoryId,
            abacaType: inv.abacaType,
            employeeId: employeeId,
            employeeName: empName,
            quantityKg: qty,
            reason: reason,
            notes: notes,
            date: dateOnly,
            createdAt: now,
            updatedAt: now,
          ),
        );

        FirestoreAuditRepository.setAuditInTransaction(
          tx,
          _firestore,
          actorEmployeeId: employeeId,
          action: AuditAction.stockAdjusted,
          entityType: AuditEntityType.stockOut,
          entityId: outRef.id,
          description:
              'Recorded manual stock-out (${reason.dbValue}): $qty kg of ${inv.abacaType}.',
          timestamp: now,
        );

        return StockOut(
          id: outRef.id,
          inventoryId: inventoryId,
          employeeId: employeeId,
          quantityKg: qty,
          reason: reason,
          notes: notes?.trim().isEmpty == true ? null : notes?.trim(),
          date: dateOnly,
          createdAt: now,
          updatedAt: now,
        );
      });

      return Ok<StockOut>(created);
    } catch (error) {
      return Err<StockOut>(
        FirestoreHelpers.mapError(error, entityName: 'StockOut'),
      );
    }
  }

  @override
  Future<Result<StockOut>> getStockOutById(String id) async {
    try {
      final doc = await _stockOuts.doc(id).get();
      if (!doc.exists || doc.data() == null) {
        return Err<StockOut>(
          NotFoundFailure(
            entityName: 'StockOut',
            entityId: id,
            message: 'StockOut $id was not found.',
          ),
        );
      }
      return Ok<StockOut>(StockOutFirestoreDto.fromFirestore(doc));
    } catch (error) {
      return Err<StockOut>(
        FirestoreHelpers.mapError(error, entityName: 'StockOut', entityId: id),
      );
    }
  }

  @override
  Future<Result<List<StockOut>>> getStockOuts({
    String? inventoryId,
    StockOutReason? reason,
    String? orderId,
    DateRangeFilter? dateRange,
  }) async {
    final rangeFailure = InputValidators.validateDateRange(dateRange);
    if (rangeFailure != null) return Err<List<StockOut>>(rangeFailure);

    try {
      Query<Map<String, dynamic>> query = _stockOuts;
      if (inventoryId != null) {
        query = query.where('inventory_id', isEqualTo: inventoryId);
      }
      if (reason != null) {
        query = query.where('reason', isEqualTo: reason.dbValue);
      }
      if (orderId != null && inventoryId == null && reason == null) {
        query = query.where('order_id', isEqualTo: orderId);
      }

      final snapshot = await query.orderBy('date', descending: true).get();
      var list = snapshot.docs.map(StockOutFirestoreDto.fromFirestore);
      if (orderId != null) {
        list = list.where((e) => e.orderId == orderId);
      }
      if (dateRange != null) {
        list = list.where((e) => dateRange.contains(e.date));
      }
      return Ok<List<StockOut>>(list.toList(growable: false));
    } catch (error) {
      return Err<List<StockOut>>(
        FirestoreHelpers.mapError(error, entityName: 'StockOut'),
      );
    }
  }

  @override
  Stream<List<StockOut>> watchStockOuts({
    String? inventoryId,
    StockOutReason? reason,
  }) {
    Query<Map<String, dynamic>> query = _stockOuts;
    if (inventoryId != null) {
      query = query.where('inventory_id', isEqualTo: inventoryId);
    }
    if (reason != null) {
      query = query.where('reason', isEqualTo: reason.dbValue);
    }
    return query.orderBy('date', descending: true).snapshots().map(
          (snapshot) => snapshot.docs
              .map(StockOutFirestoreDto.fromFirestore)
              .toList(growable: false),
        );
  }

  @override
  Future<Result<void>> deleteStockOut(
    String id, {
    String? actorEmployeeId,
  }) async {
    try {
      final outRef = _stockOuts.doc(id);
      final now = DateTime.now().toUtc();

      await _firestore.runTransaction<void>((tx) async {
        // 1. ALL READS FIRST
        final outSnap = await tx.get(outRef);
        if (!outSnap.exists || outSnap.data() == null) {
          throw NotFoundFailure(
            entityName: 'StockOut',
            entityId: id,
            message: 'StockOut $id was not found.',
          );
        }
        final stockOut = StockOutFirestoreDto.fromFirestore(outSnap);
        if (stockOut.deliveryId != null) {
          throw const InvalidStateTransitionFailure(
            entityName: 'StockOut',
            currentState: 'delivery_linked',
            attemptedAction: 'delete_stock_out',
            message: 'Delivery-linked stock-out records cannot be deleted.',
          );
        }

        final invRef = _firestore
            .collection(FirestoreCollections.inventory)
            .doc(stockOut.inventoryId);
        final invSnap = await tx.get(invRef);
        if (!invSnap.exists || invSnap.data() == null) {
          throw NotFoundFailure(
            entityName: 'Inventory',
            entityId: stockOut.inventoryId,
            message: 'Inventory grade ${stockOut.inventoryId} was not found.',
          );
        }
        final inv = InventoryFirestoreDto.fromFirestore(invSnap);

        // 2. ALL WRITES AFTER READS
        tx.update(invRef, <String, dynamic>{
          'current_stock_kg': DecimalPrecision.add2(
            inv.currentStockKg,
            stockOut.quantityKg,
          ),
          'last_updated': FirestoreHelpers.toTimestamp(now),
        });
        tx.delete(outRef);

        FirestoreAuditRepository.setAuditInTransaction(
          tx,
          _firestore,
          actorEmployeeId: actorEmployeeId,
          action: AuditAction.deleted,
          entityType: AuditEntityType.stockOut,
          entityId: id,
          description:
              'Deleted manual stock-out and restored ${stockOut.quantityKg} kg.',
          timestamp: now,
        );
      });

      return const Ok<void>(null);
    } catch (error) {
      return Err<void>(
        FirestoreHelpers.mapError(error, entityName: 'StockOut', entityId: id),
      );
    }
  }
}
