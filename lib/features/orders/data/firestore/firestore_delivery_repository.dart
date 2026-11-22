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
import '../../../inventory/data/firestore/inventory_firestore_dto.dart';
import '../../../inventory/data/firestore/stock_out_firestore_dto.dart';
import '../../../inventory/domain/entities/stock_out_reason.dart';
import '../../domain/entities/delivery.dart';
import '../../domain/entities/delivery_status.dart';
import '../../domain/entities/order_status.dart';
import '../../domain/repositories/delivery_repository.dart';
import 'delivery_firestore_dto.dart';
import 'order_firestore_dto.dart';

/// Cloud Firestore implementation of [DeliveryRepository].
///
/// Workarounds:
/// - `order_delivery_locks/{orderId}` guarantees strict 1:1 per order inside
///   `runTransaction` while keeping `deliveries` as a root collection for fast
///   driver dispatch streams.
/// - `completeDelivery` runs one atomic `runTransaction` that checks stock,
///   decrements `inventory` ONCE, inserts a linked `stock_outs` record, updates
///   both `deliveries` and `orders`, and appends `activity_logs`.
final class FirestoreDeliveryRepository implements DeliveryRepository {
  FirestoreDeliveryRepository(this._firestore);

  final FirebaseFirestore _firestore;

  CollectionReference<Map<String, dynamic>> get _deliveries =>
      _firestore.collection(FirestoreCollections.deliveries);

  @override
  Future<Result<Delivery>> scheduleDelivery({
    required String orderId,
    required String employeeId,
    required DateTime deliveryDate,
    String? notes,
    String? actorEmployeeId,
  }) async {
    final errors = <String, String>{};
    InputValidators.requireNonEmpty(errors, 'orderId', orderId);
    InputValidators.requireNonEmpty(errors, 'employeeId', employeeId);
    final validation = InputValidators.toFailure(errors);
    if (validation != null) return Err<Delivery>(validation);

    try {
      final now = DateTime.now().toUtc();
      final dateOnly =
          DateTime(deliveryDate.year, deliveryDate.month, deliveryDate.day);
      final orderRef =
          _firestore.collection(FirestoreCollections.orders).doc(orderId);
      final empRef =
          _firestore.collection(FirestoreCollections.employees).doc(employeeId);
      final lockRef = _firestore
          .collection(FirestoreCollections.orderDeliveryLocks)
          .doc(orderId);
      final deliveryRef = _deliveries.doc();

      final created = await _firestore.runTransaction<Delivery>((tx) async {
        // 1. ALL READS FIRST
        final orderSnap = await tx.get(orderRef);
        if (!orderSnap.exists || orderSnap.data() == null) {
          throw NotFoundFailure(
            entityName: 'Order',
            entityId: orderId,
            message: 'Order $orderId was not found.',
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
        final lockSnap = await tx.get(lockRef);
        if (lockSnap.exists) {
          throw ConflictFailure(
            message: 'A delivery is already scheduled for order $orderId.',
            code: 'unique_violation',
          );
        }

        final order = OrderFirestoreDto.fromFirestore(orderSnap);
        if (order.status != OrderStatus.stocked) {
          throw InvalidStateTransitionFailure(
            entityName: 'Order',
            currentState: order.status.dbValue,
            attemptedAction: 'schedule_delivery',
            message: 'Deliveries can only be scheduled for stocked orders.',
          );
        }

        final empData = empSnap.data()!;
        final empName = FirestoreHelpers.formatFullName(
          firstName: empData['first_name'] as String,
          middleName: empData['middle_name'] as String?,
          lastName: empData['last_name'] as String,
        );

        final entity = Delivery(
          id: deliveryRef.id,
          orderId: orderId,
          employeeId: employeeId,
          deliveryDate: dateOnly,
          status: DeliveryStatus.pending,
          notes: notes?.trim().isEmpty == true ? null : notes?.trim(),
          createdAt: now,
          updatedAt: now,
        );

        // 2. ALL WRITES AFTER READS
        tx.set(lockRef, <String, dynamic>{
          'delivery_id': entity.id,
          'order_id': orderId,
        });
        tx.set(
          deliveryRef,
          DeliveryFirestoreDto.toFirestore(
            orderId: entity.orderId,
            employeeId: entity.employeeId,
            employeeName: empName,
            deliveryDate: entity.deliveryDate,
            status: entity.status,
            notes: entity.notes,
            createdAt: now,
            updatedAt: now,
          ),
        );
        tx.update(orderRef, <String, dynamic>{
          'delivery_id': entity.id,
          'delivery_status': DeliveryStatus.pending.dbValue,
          'updated_at': FirestoreHelpers.toTimestamp(now),
        });

        FirestoreAuditRepository.setAuditInTransaction(
          tx,
          _firestore,
          actorEmployeeId: actorEmployeeId ?? employeeId,
          action: AuditAction.created,
          entityType: AuditEntityType.delivery,
          entityId: entity.id,
          description: 'Scheduled delivery for order $orderId.',
          timestamp: now,
        );

        return entity;
      });

      return Ok<Delivery>(created);
    } catch (error) {
      return Err<Delivery>(
        FirestoreHelpers.mapError(error, entityName: 'Delivery'),
      );
    }
  }

  @override
  Future<Result<Delivery>> completeDelivery({
    required String deliveryId,
    required String actorEmployeeId,
    DateTime? deliveredAt,
    String? notes,
  }) async {
    try {
      final deliveryRef = _deliveries.doc(deliveryId);
      final actorRef = _firestore
          .collection(FirestoreCollections.employees)
          .doc(actorEmployeeId);
      final now = DateTime.now().toUtc();
      final effectiveDeliveredAt = (deliveredAt ?? now).toUtc();

      final completed = await _firestore.runTransaction<Delivery>((tx) async {
        // 1. ALL READS FIRST
        final delSnap = await tx.get(deliveryRef);
        if (!delSnap.exists || delSnap.data() == null) {
          throw NotFoundFailure(
            entityName: 'Delivery',
            entityId: deliveryId,
            message: 'Delivery $deliveryId was not found.',
          );
        }
        final delivery = DeliveryFirestoreDto.fromFirestore(delSnap);
        if (delivery.status != DeliveryStatus.pending) {
          throw InvalidStateTransitionFailure(
            entityName: 'Delivery',
            currentState: delivery.status.dbValue,
            attemptedAction: 'complete_delivery',
            message:
                'Delivery $deliveryId is already ${delivery.status.dbValue}.',
          );
        }

        final orderRef = _firestore
            .collection(FirestoreCollections.orders)
            .doc(delivery.orderId);
        final orderSnap = await tx.get(orderRef);
        if (!orderSnap.exists || orderSnap.data() == null) {
          throw NotFoundFailure(
            entityName: 'Order',
            entityId: delivery.orderId,
            message: 'Order ${delivery.orderId} was not found.',
          );
        }
        final order = OrderFirestoreDto.fromFirestore(orderSnap);
        if (order.status != OrderStatus.stocked) {
          throw InvalidStateTransitionFailure(
            entityName: 'Order',
            currentState: order.status.dbValue,
            attemptedAction: 'complete_delivery',
            message:
                'Order must be in stocked state before completing delivery (current: ${order.status.dbValue}).',
          );
        }

        final invRef = _firestore
            .collection(FirestoreCollections.inventory)
            .doc(order.inventoryId);
        final invSnap = await tx.get(invRef);
        if (!invSnap.exists || invSnap.data() == null) {
          throw NotFoundFailure(
            entityName: 'Inventory',
            entityId: order.inventoryId,
            message: 'Inventory grade ${order.inventoryId} was not found.',
          );
        }
        final inv = InventoryFirestoreDto.fromFirestore(invSnap);

        final actorSnap = await tx.get(actorRef);
        final actorData = actorSnap.data();
        final actorName = actorData == null
            ? actorEmployeeId
            : FirestoreHelpers.formatFullName(
                firstName: actorData['first_name'] as String,
                middleName: actorData['middle_name'] as String?,
                lastName: actorData['last_name'] as String,
              );

        if (DecimalPrecision.compare2(inv.currentStockKg, order.quantityKg) <
            0) {
          throw InsufficientStockFailure(
            abacaType: inv.abacaType,
            availableKg: inv.currentStockKg,
            requestedKg: order.quantityKg,
            message:
                'Insufficient ${inv.abacaType} stock to complete delivery.',
          );
        }

        final trimmedNotes = notes?.trim();
        final nextNotes =
            (trimmedNotes == null || trimmedNotes.isEmpty)
                ? delivery.notes
                : trimmedNotes;

        final updatedDelivery = delivery.copyWith(
          status: DeliveryStatus.delivered,
          deliveredAt: effectiveDeliveredAt,
          notes: nextNotes,
          clearNotes: nextNotes == null,
          updatedAt: now,
        );

        final stockOutRef =
            _firestore.collection(FirestoreCollections.stockOuts).doc();
        final releaseDate = DateTime(
          effectiveDeliveredAt.year,
          effectiveDeliveredAt.month,
          effectiveDeliveredAt.day,
        );

        // 2. ALL WRITES AFTER READS
        tx.update(invRef, <String, dynamic>{
          'current_stock_kg': DecimalPrecision.subtract2(
            inv.currentStockKg,
            order.quantityKg,
          ),
          'last_updated': FirestoreHelpers.toTimestamp(now),
        });

        tx.set(
          stockOutRef,
          StockOutFirestoreDto.toFirestore(
            inventoryId: inv.id,
            abacaType: inv.abacaType,
            employeeId: actorEmployeeId,
            employeeName: actorName,
            deliveryId: delivery.id,
            orderId: order.id,
            quantityKg: order.quantityKg,
            reason: StockOutReason.released,
            notes: nextNotes ?? 'Auto-released on delivery completion.',
            date: releaseDate,
            createdAt: now,
            updatedAt: now,
          ),
        );

        tx.update(deliveryRef, <String, dynamic>{
          'status': DeliveryStatus.delivered.dbValue,
          'delivered_at': FirestoreHelpers.toTimestamp(effectiveDeliveredAt),
          'notes': nextNotes,
          'updated_at': FirestoreHelpers.toTimestamp(now),
        });

        tx.update(orderRef, <String, dynamic>{
          'status': OrderStatus.delivered.dbValue,
          'delivery_status': DeliveryStatus.delivered.dbValue,
          'updated_at': FirestoreHelpers.toTimestamp(now),
        });

        FirestoreAuditRepository.setAuditInTransaction(
          tx,
          _firestore,
          actorEmployeeId: actorEmployeeId,
          action: AuditAction.deliveryCompleted,
          entityType: AuditEntityType.delivery,
          entityId: deliveryId,
          description:
              'Completed delivery for order ${order.id} (${order.quantityKg} kg of ${inv.abacaType} released).',
          oldValues: <String, Object?>{'status': delivery.status.dbValue},
          newValues: <String, Object?>{
            'status': updatedDelivery.status.dbValue,
            'delivered_at': effectiveDeliveredAt.toIso8601String(),
          },
          timestamp: now,
        );

        return updatedDelivery;
      });

      return Ok<Delivery>(completed);
    } catch (error) {
      return Err<Delivery>(
        FirestoreHelpers.mapError(
          error,
          entityName: 'Delivery',
          entityId: deliveryId,
        ),
      );
    }
  }

  @override
  Future<Result<Delivery>> getDeliveryById(String id) async {
    try {
      final doc = await _deliveries.doc(id).get();
      if (!doc.exists || doc.data() == null) {
        return Err<Delivery>(
          NotFoundFailure(
            entityName: 'Delivery',
            entityId: id,
            message: 'Delivery $id was not found.',
          ),
        );
      }
      return Ok<Delivery>(DeliveryFirestoreDto.fromFirestore(doc));
    } catch (error) {
      return Err<Delivery>(
        FirestoreHelpers.mapError(error, entityName: 'Delivery', entityId: id),
      );
    }
  }

  @override
  Future<Result<Delivery?>> getDeliveryByOrderId(String orderId) async {
    try {
      final lockSnap = await _firestore
          .collection(FirestoreCollections.orderDeliveryLocks)
          .doc(orderId)
          .get();
      final deliveryId = lockSnap.data()?['delivery_id'] as String?;
      if (lockSnap.exists && deliveryId != null) {
        final doc = await _deliveries.doc(deliveryId).get();
        if (doc.exists && doc.data() != null) {
          return Ok<Delivery?>(DeliveryFirestoreDto.fromFirestore(doc));
        }
      }

      final snapshot = await _deliveries
          .where('order_id', isEqualTo: orderId)
          .limit(1)
          .get();
      if (snapshot.docs.isEmpty) return const Ok<Delivery?>(null);
      return Ok<Delivery?>(
        DeliveryFirestoreDto.fromFirestore(snapshot.docs.first),
      );
    } catch (error) {
      return Err<Delivery?>(
        FirestoreHelpers.mapError(error, entityName: 'Delivery'),
      );
    }
  }

  @override
  Future<Result<List<Delivery>>> getDeliveries({
    String? employeeId,
    DeliveryStatus? status,
    DateRangeFilter? dateRange,
  }) async {
    final rangeFailure = InputValidators.validateDateRange(dateRange);
    if (rangeFailure != null) return Err<List<Delivery>>(rangeFailure);

    try {
      Query<Map<String, dynamic>> query = _deliveries;
      if (employeeId != null) {
        query = query.where('employee_id', isEqualTo: employeeId);
      }
      if (status != null) {
        query = query.where('status', isEqualTo: status.dbValue);
      }

      final snapshot =
          await query.orderBy('delivery_date', descending: true).get();
      var list = snapshot.docs.map(DeliveryFirestoreDto.fromFirestore);
      if (dateRange != null) {
        list = list.where((d) => dateRange.contains(d.deliveryDate));
      }
      return Ok<List<Delivery>>(list.toList(growable: false));
    } catch (error) {
      return Err<List<Delivery>>(
        FirestoreHelpers.mapError(error, entityName: 'Delivery'),
      );
    }
  }

  @override
  Stream<List<Delivery>> watchDeliveries({
    String? employeeId,
    DeliveryStatus? status,
  }) {
    Query<Map<String, dynamic>> query = _deliveries;
    if (employeeId != null) {
      query = query.where('employee_id', isEqualTo: employeeId);
    }
    if (status != null) {
      query = query.where('status', isEqualTo: status.dbValue);
    }
    return query.orderBy('delivery_date', descending: false).snapshots().map(
          (snapshot) => snapshot.docs
              .map(DeliveryFirestoreDto.fromFirestore)
              .toList(growable: false),
        );
  }

  @override
  Future<Result<Delivery>> reassignDelivery({
    required String deliveryId,
    required String newEmployeeId,
    DateTime? newDeliveryDate,
    String? notes,
    required String actorEmployeeId,
  }) async {
    final errors = <String, String>{};
    InputValidators.requireNonEmpty(errors, 'newEmployeeId', newEmployeeId);
    final validation = InputValidators.toFailure(errors);
    if (validation != null) return Err<Delivery>(validation);

    try {
      final deliveryRef = _deliveries.doc(deliveryId);
      final newEmpRef = _firestore
          .collection(FirestoreCollections.employees)
          .doc(newEmployeeId);
      final now = DateTime.now().toUtc();

      final updated = await _firestore.runTransaction<Delivery>((tx) async {
        // 1. ALL READS FIRST
        final delSnap = await tx.get(deliveryRef);
        if (!delSnap.exists || delSnap.data() == null) {
          throw NotFoundFailure(
            entityName: 'Delivery',
            entityId: deliveryId,
            message: 'Delivery $deliveryId was not found.',
          );
        }
        final current = DeliveryFirestoreDto.fromFirestore(delSnap);
        if (current.status != DeliveryStatus.pending) {
          throw InvalidStateTransitionFailure(
            entityName: 'Delivery',
            currentState: current.status.dbValue,
            attemptedAction: 'reassign_delivery',
            message: 'Completed deliveries cannot be reassigned.',
          );
        }

        final empSnap = await tx.get(newEmpRef);
        if (!empSnap.exists || empSnap.data() == null) {
          throw NotFoundFailure(
            entityName: 'Employee',
            entityId: newEmployeeId,
            message: 'Employee $newEmployeeId was not found.',
          );
        }
        final empData = empSnap.data()!;
        final empName = FirestoreHelpers.formatFullName(
          firstName: empData['first_name'] as String,
          middleName: empData['middle_name'] as String?,
          lastName: empData['last_name'] as String,
        );

        final nextDate = newDeliveryDate == null
            ? current.deliveryDate
            : DateTime(
                newDeliveryDate.year,
                newDeliveryDate.month,
                newDeliveryDate.day,
              );
        final nextNotes = notes == null
            ? current.notes
            : (notes.trim().isEmpty ? null : notes.trim());

        final next = current.copyWith(
          employeeId: newEmployeeId,
          deliveryDate: nextDate,
          notes: nextNotes,
          clearNotes: nextNotes == null,
          updatedAt: now,
        );

        // 2. ALL WRITES AFTER READS
        tx.update(deliveryRef, <String, dynamic>{
          'employee_id': newEmployeeId,
          'employee_name': empName,
          'delivery_date': FirestoreHelpers.toDateOnlyTimestamp(nextDate),
          'notes': nextNotes,
          'updated_at': FirestoreHelpers.toTimestamp(now),
        });

        FirestoreAuditRepository.setAuditInTransaction(
          tx,
          _firestore,
          actorEmployeeId: actorEmployeeId,
          action: AuditAction.updated,
          entityType: AuditEntityType.delivery,
          entityId: deliveryId,
          description: 'Reassigned delivery $deliveryId to $newEmployeeId.',
          timestamp: now,
        );
        return next;
      });

      return Ok<Delivery>(updated);
    } catch (error) {
      return Err<Delivery>(
        FirestoreHelpers.mapError(
          error,
          entityName: 'Delivery',
          entityId: deliveryId,
        ),
      );
    }
  }
}
