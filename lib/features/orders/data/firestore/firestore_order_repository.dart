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
import '../../../finance/data/firestore/payment_firestore_dto.dart';
import '../../../inventory/data/firestore/inventory_firestore_dto.dart';
import '../../domain/entities/delivery.dart';
import '../../domain/entities/delivery_status.dart';
import '../../domain/entities/order.dart';
import '../../domain/entities/order_status.dart';
import '../../domain/repositories/order_repository.dart';
import 'delivery_firestore_dto.dart';
import 'order_firestore_dto.dart';

/// Cloud Firestore implementation of [OrderRepository].
final class FirestoreOrderRepository implements OrderRepository {
  FirestoreOrderRepository(this._firestore);

  final FirebaseFirestore _firestore;

  CollectionReference<Map<String, dynamic>> get _orders =>
      _firestore.collection(FirestoreCollections.orders);

  @override
  Future<Result<Order>> createOrder({
    required String customerId,
    required String employeeId,
    required String inventoryId,
    required DateTime orderDate,
    required double quantityKg,
    required double pricePerKg,
    String? notes,
  }) async {
    final errors = <String, String>{};
    InputValidators.requireNonEmpty(errors, 'customerId', customerId);
    InputValidators.requireNonEmpty(errors, 'employeeId', employeeId);
    InputValidators.requireNonEmpty(errors, 'inventoryId', inventoryId);
    InputValidators.requirePositive(errors, 'quantityKg', quantityKg);
    InputValidators.requireNonNegative(errors, 'pricePerKg', pricePerKg);
    final validation = InputValidators.toFailure(errors);
    if (validation != null) return Err<Order>(validation);

    try {
      final now = DateTime.now().toUtc();
      final dateOnly = DateTime(orderDate.year, orderDate.month, orderDate.day);
      final qty = DecimalPrecision.round2(quantityKg);
      final price = DecimalPrecision.round2(pricePerKg);
      final totalAmount = DecimalPrecision.multiply2(qty, price);

      final orderRef = _orders.doc();
      final customerRef =
          _firestore.collection(FirestoreCollections.customers).doc(customerId);
      final employeeRef =
          _firestore.collection(FirestoreCollections.employees).doc(employeeId);
      final invRef =
          _firestore.collection(FirestoreCollections.inventory).doc(inventoryId);

      final created = await _firestore.runTransaction<Order>((tx) async {
        // 1. ALL READS FIRST
        final custSnap = await tx.get(customerRef);
        if (!custSnap.exists || custSnap.data() == null) {
          throw NotFoundFailure(
            entityName: 'Customer',
            entityId: customerId,
            message: 'Customer $customerId was not found.',
          );
        }
        final empSnap = await tx.get(employeeRef);
        if (!empSnap.exists || empSnap.data() == null) {
          throw NotFoundFailure(
            entityName: 'Employee',
            entityId: employeeId,
            message: 'Employee $employeeId was not found.',
          );
        }
        final invSnap = await tx.get(invRef);
        if (!invSnap.exists || invSnap.data() == null) {
          throw NotFoundFailure(
            entityName: 'Inventory',
            entityId: inventoryId,
            message: 'Inventory grade $inventoryId was not found.',
          );
        }

        final inv = InventoryFirestoreDto.fromFirestore(invSnap);
        final custData = custSnap.data()!;
        final empData = empSnap.data()!;
        final customerName = FirestoreHelpers.formatFullName(
          firstName: custData['first_name'] as String,
          middleName: custData['middle_name'] as String?,
          lastName: custData['last_name'] as String,
        );
        final employeeName = FirestoreHelpers.formatFullName(
          firstName: empData['first_name'] as String,
          middleName: empData['middle_name'] as String?,
          lastName: empData['last_name'] as String,
        );

        final entity = Order(
          id: orderRef.id,
          customerId: customerId,
          employeeId: employeeId,
          inventoryId: inventoryId,
          abacaType: inv.abacaType,
          orderDate: dateOnly,
          quantityKg: qty,
          pricePerKg: price,
          totalAmount: totalAmount,
          status: OrderStatus.pending,
          notes: notes?.trim().isEmpty == true ? null : notes?.trim(),
          createdAt: now,
          updatedAt: now,
        );

        // 2. ALL WRITES AFTER READS
        tx.set(
          orderRef,
          OrderFirestoreDto.toFirestore(
            customerId: entity.customerId,
            customerName: customerName,
            employeeId: entity.employeeId,
            employeeName: employeeName,
            inventoryId: entity.inventoryId,
            abacaType: entity.abacaType,
            orderDate: entity.orderDate,
            quantityKg: entity.quantityKg,
            pricePerKg: entity.pricePerKg,
            totalAmount: entity.totalAmount,
            status: entity.status,
            paidAmount: 0.0,
            notes: entity.notes,
            createdAt: now,
            updatedAt: now,
          ),
        );

        FirestoreAuditRepository.setAuditInTransaction(
          tx,
          _firestore,
          actorEmployeeId: employeeId,
          action: AuditAction.created,
          entityType: AuditEntityType.order,
          entityId: entity.id,
          description:
              'Created order for ${entity.quantityKg} kg of ${entity.abacaType}.',
          newValues: <String, Object?>{
            'customer_id': entity.customerId,
            'inventory_id': entity.inventoryId,
            'quantity_kg': entity.quantityKg,
            'total_amount': entity.totalAmount,
          },
          timestamp: now,
        );

        return entity;
      });

      return Ok<Order>(created);
    } catch (error) {
      return Err<Order>(
        FirestoreHelpers.mapError(error, entityName: 'Order'),
      );
    }
  }

  @override
  Future<Result<Order>> getOrderById(String id) async {
    try {
      final doc = await _orders.doc(id).get();
      if (!doc.exists || doc.data() == null) {
        return Err<Order>(
          NotFoundFailure(
            entityName: 'Order',
            entityId: id,
            message: 'Order $id was not found.',
          ),
        );
      }
      return Ok<Order>(OrderFirestoreDto.fromFirestore(doc));
    } catch (error) {
      return Err<Order>(
        FirestoreHelpers.mapError(error, entityName: 'Order', entityId: id),
      );
    }
  }

  @override
  Future<Result<OrderWithDetails>> getOrderWithDetails(String id) async {
    try {
      final orderRef = _orders.doc(id);
      final orderSnap = await orderRef.get();
      if (!orderSnap.exists || orderSnap.data() == null) {
        return Err<OrderWithDetails>(
          NotFoundFailure(
            entityName: 'Order',
            entityId: id,
            message: 'Order $id was not found.',
          ),
        );
      }

      final paymentsSnap = await orderRef
          .collection(FirestoreCollections.paymentsSubcollection)
          .orderBy('payment_date', descending: false)
          .get();

      final payments = paymentsSnap.docs
          .map(PaymentFirestoreDto.fromFirestore)
          .toList(growable: false);

      Delivery? delivery;
      final cachedDeliveryId = orderSnap.data()!['delivery_id'] as String?;
      if (cachedDeliveryId != null) {
        final delSnap = await _firestore
            .collection(FirestoreCollections.deliveries)
            .doc(cachedDeliveryId)
            .get();
        if (delSnap.exists && delSnap.data() != null) {
          delivery = DeliveryFirestoreDto.fromFirestore(delSnap);
        }
      } else {
        final delQuery = await _firestore
            .collection(FirestoreCollections.deliveries)
            .where('order_id', isEqualTo: id)
            .limit(1)
            .get();
        if (delQuery.docs.isNotEmpty) {
          delivery = DeliveryFirestoreDto.fromFirestore(delQuery.docs.first);
        }
      }

      return Ok<OrderWithDetails>(
        OrderFirestoreDto.detailsFromFirestore(
          orderDoc: orderSnap,
          delivery: delivery,
          payments: payments,
        ),
      );
    } catch (error) {
      return Err<OrderWithDetails>(
        FirestoreHelpers.mapError(error, entityName: 'Order', entityId: id),
      );
    }
  }

  @override
  Future<Result<List<Order>>> getOrders({
    String? customerId,
    String? employeeId,
    String? inventoryId,
    OrderStatus? status,
    DateRangeFilter? dateRange,
  }) async {
    final rangeFailure = InputValidators.validateDateRange(dateRange);
    if (rangeFailure != null) return Err<List<Order>>(rangeFailure);

    try {
      Query<Map<String, dynamic>> query = _orders;
      if (customerId != null) {
        query = query.where('customer_id', isEqualTo: customerId);
        if (status != null) {
          query = query.where('status', isEqualTo: status.dbValue);
        }
      } else if (status != null) {
        query = query.where('status', isEqualTo: status.dbValue);
      } else if (employeeId != null) {
        query = query.where('employee_id', isEqualTo: employeeId);
      } else if (inventoryId != null) {
        query = query.where('inventory_id', isEqualTo: inventoryId);
      }

      final snapshot = await query.orderBy('order_date', descending: true).get();
      var orders = snapshot.docs.map(OrderFirestoreDto.fromFirestore);
      if (employeeId != null) {
        orders = orders.where((o) => o.employeeId == employeeId);
      }
      if (inventoryId != null) {
        orders = orders.where((o) => o.inventoryId == inventoryId);
      }
      if (dateRange != null) {
        orders = orders.where((o) => dateRange.contains(o.orderDate));
      }
      return Ok<List<Order>>(orders.toList(growable: false));
    } catch (error) {
      return Err<List<Order>>(
        FirestoreHelpers.mapError(error, entityName: 'Order'),
      );
    }
  }

  @override
  Stream<List<Order>> watchOrders({
    String? customerId,
    OrderStatus? status,
  }) {
    Query<Map<String, dynamic>> query = _orders;
    if (customerId != null) {
      query = query.where('customer_id', isEqualTo: customerId);
    }
    if (status != null) {
      query = query.where('status', isEqualTo: status.dbValue);
    }
    return query.orderBy('order_date', descending: true).snapshots().map(
          (snapshot) => snapshot.docs
              .map(OrderFirestoreDto.fromFirestore)
              .toList(growable: false),
        );
  }

  @override
  Future<Result<Order>> markOrderStocked({
    required String orderId,
    required String actorEmployeeId,
  }) async {
    try {
      final orderRef = _orders.doc(orderId);
      final now = DateTime.now().toUtc();

      final updated = await _firestore.runTransaction<Order>((tx) async {
        // 1. ALL READS FIRST
        final orderSnap = await tx.get(orderRef);
        if (!orderSnap.exists || orderSnap.data() == null) {
          throw NotFoundFailure(
            entityName: 'Order',
            entityId: orderId,
            message: 'Order $orderId was not found.',
          );
        }
        final order = OrderFirestoreDto.fromFirestore(orderSnap);
        if (order.status != OrderStatus.pending) {
          throw InvalidStateTransitionFailure(
            entityName: 'Order',
            currentState: order.status.dbValue,
            attemptedAction: 'mark_order_stocked',
            message: 'Only pending orders can be marked stocked.',
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

        if (DecimalPrecision.compare2(inv.currentStockKg, order.quantityKg) <
            0) {
          throw InsufficientStockFailure(
            abacaType: inv.abacaType,
            availableKg: inv.currentStockKg,
            requestedKg: order.quantityKg,
            message:
                'Insufficient ${inv.abacaType} stock to mark order stocked.',
          );
        }

        // 2. ALL WRITES AFTER READS
        final next = order.copyWith(status: OrderStatus.stocked, updatedAt: now);
        tx.update(orderRef, <String, dynamic>{
          'status': OrderStatus.stocked.dbValue,
          'updated_at': FirestoreHelpers.toTimestamp(now),
        });

        FirestoreAuditRepository.setAuditInTransaction(
          tx,
          _firestore,
          actorEmployeeId: actorEmployeeId,
          action: AuditAction.statusChanged,
          entityType: AuditEntityType.order,
          entityId: orderId,
          description: 'Marked order as stocked.',
          oldValues: <String, Object?>{'status': order.status.dbValue},
          newValues: <String, Object?>{'status': next.status.dbValue},
          timestamp: now,
        );
        return next;
      });

      return Ok<Order>(updated);
    } catch (error) {
      return Err<Order>(
        FirestoreHelpers.mapError(error, entityName: 'Order', entityId: orderId),
      );
    }
  }

  @override
  Future<Result<Order>> cancelOrder({
    required String orderId,
    required String actorEmployeeId,
    String? reason,
  }) async {
    try {
      final orderRef = _orders.doc(orderId);
      final prePayments = await orderRef
          .collection(FirestoreCollections.paymentsSubcollection)
          .limit(1)
          .get();
      if (prePayments.docs.isNotEmpty) {
        return const Err<Order>(
          InvalidStateTransitionFailure(
            entityName: 'Order',
            currentState: 'has_payments',
            attemptedAction: 'cancel_order',
            message:
                'Cannot cancel an order with active payments. Void payments first.',
          ),
        );
      }

      final lockRef = _firestore
          .collection(FirestoreCollections.orderDeliveryLocks)
          .doc(orderId);
      final now = DateTime.now().toUtc();

      final updated = await _firestore.runTransaction<Order>((tx) async {
        // 1. ALL READS FIRST
        final orderSnap = await tx.get(orderRef);
        if (!orderSnap.exists || orderSnap.data() == null) {
          throw NotFoundFailure(
            entityName: 'Order',
            entityId: orderId,
            message: 'Order $orderId was not found.',
          );
        }
        final order = OrderFirestoreDto.fromFirestore(orderSnap);
        final paidAmount =
            FirestoreHelpers.parseDouble(orderSnap.data()!['paid_amount']);

        if (order.status == OrderStatus.delivered ||
            order.status == OrderStatus.cancelled) {
          throw InvalidStateTransitionFailure(
            entityName: 'Order',
            currentState: order.status.dbValue,
            attemptedAction: 'cancel_order',
            message: 'Cannot cancel order in status ${order.status.dbValue}.',
          );
        }
        if (DecimalPrecision.compare2(paidAmount, 0) > 0) {
          throw const InvalidStateTransitionFailure(
            entityName: 'Order',
            currentState: 'has_payments',
            attemptedAction: 'cancel_order',
            message:
                'Cannot cancel an order with active payments. Void payments first.',
          );
        }

        final lockSnap = await tx.get(lockRef);
        DocumentReference<Map<String, dynamic>>? deliveryRef;
        if (lockSnap.exists && lockSnap.data() != null) {
          final deliveryId = lockSnap.data()!['delivery_id'] as String?;
          if (deliveryId != null) {
            deliveryRef = _firestore
                .collection(FirestoreCollections.deliveries)
                .doc(deliveryId);
            final delSnap = await tx.get(deliveryRef);
            if (delSnap.exists && delSnap.data() != null) {
              final del = DeliveryFirestoreDto.fromFirestore(delSnap);
              if (del.status == DeliveryStatus.delivered) {
                throw const InvalidStateTransitionFailure(
                  entityName: 'Order',
                  currentState: 'delivered',
                  attemptedAction: 'cancel_order',
                  message:
                      'Cannot cancel an order whose delivery is already delivered.',
                );
              }
            }
          }
        }

        // 2. ALL WRITES AFTER READS
        final trimmedReason = reason?.trim();
        String? nextNotes = order.notes;
        if (trimmedReason != null && trimmedReason.isNotEmpty) {
          nextNotes = nextNotes == null || nextNotes.isEmpty
              ? '[Cancelled] $trimmedReason'
              : '$nextNotes\n[Cancelled] $trimmedReason';
        }

        if (deliveryRef != null) {
          tx.delete(deliveryRef);
          tx.delete(lockRef);
        }

        final next = order.copyWith(
          status: OrderStatus.cancelled,
          notes: nextNotes,
          clearNotes: nextNotes == null,
          updatedAt: now,
        );

        tx.update(orderRef, <String, dynamic>{
          'status': OrderStatus.cancelled.dbValue,
          'delivery_id': null,
          'delivery_status': null,
          'notes': next.notes,
          'updated_at': FirestoreHelpers.toTimestamp(now),
        });

        FirestoreAuditRepository.setAuditInTransaction(
          tx,
          _firestore,
          actorEmployeeId: actorEmployeeId,
          action: AuditAction.statusChanged,
          entityType: AuditEntityType.order,
          entityId: orderId,
          description:
              (trimmedReason != null && trimmedReason.isNotEmpty)
                  ? trimmedReason
                  : 'Order cancelled.',
          oldValues: <String, Object?>{'status': order.status.dbValue},
          newValues: <String, Object?>{'status': next.status.dbValue},
          timestamp: now,
        );
        return next;
      });

      return Ok<Order>(updated);
    } catch (error) {
      return Err<Order>(
        FirestoreHelpers.mapError(error, entityName: 'Order', entityId: orderId),
      );
    }
  }

  @override
  Future<Result<Order>> updatePendingOrder({
    required String orderId,
    String? inventoryId,
    double? quantityKg,
    double? pricePerKg,
    DateTime? orderDate,
    String? notes,
    bool clearNotes = false,
    required String actorEmployeeId,
  }) async {
    final errors = <String, String>{};
    if (quantityKg != null) {
      InputValidators.requirePositive(errors, 'quantityKg', quantityKg);
    }
    if (pricePerKg != null) {
      InputValidators.requireNonNegative(errors, 'pricePerKg', pricePerKg);
    }
    final validation = InputValidators.toFailure(errors);
    if (validation != null) return Err<Order>(validation);

    try {
      final orderRef = _orders.doc(orderId);
      final now = DateTime.now().toUtc();

      final updated = await _firestore.runTransaction<Order>((tx) async {
        // 1. ALL READS FIRST
        final orderSnap = await tx.get(orderRef);
        if (!orderSnap.exists || orderSnap.data() == null) {
          throw NotFoundFailure(
            entityName: 'Order',
            entityId: orderId,
            message: 'Order $orderId was not found.',
          );
        }
        final current = OrderFirestoreDto.fromFirestore(orderSnap);
        if (current.status != OrderStatus.pending) {
          throw InvalidStateTransitionFailure(
            entityName: 'Order',
            currentState: current.status.dbValue,
            attemptedAction: 'update_pending_order',
            message: 'Only pending orders can be edited.',
          );
        }

        var nextInvId = current.inventoryId;
        var nextAbacaType = current.abacaType;
        if (inventoryId != null && inventoryId != current.inventoryId) {
          final invSnap = await tx.get(
            _firestore
                .collection(FirestoreCollections.inventory)
                .doc(inventoryId),
          );
          if (!invSnap.exists || invSnap.data() == null) {
            throw NotFoundFailure(
              entityName: 'Inventory',
              entityId: inventoryId,
              message: 'Inventory grade $inventoryId was not found.',
            );
          }
          final inv = InventoryFirestoreDto.fromFirestore(invSnap);
          nextInvId = inv.id;
          nextAbacaType = inv.abacaType;
        }

        final nextQty = DecimalPrecision.round2(quantityKg ?? current.quantityKg);
        final nextPrice =
            DecimalPrecision.round2(pricePerKg ?? current.pricePerKg);
        final nextTotal = DecimalPrecision.multiply2(nextQty, nextPrice);
        final nextDate = orderDate != null
            ? DateTime(orderDate.year, orderDate.month, orderDate.day)
            : current.orderDate;
        final nextNotes = clearNotes
            ? null
            : (notes != null
                ? (notes.trim().isEmpty ? null : notes.trim())
                : current.notes);

        final next = current.copyWith(
          inventoryId: nextInvId,
          abacaType: nextAbacaType,
          orderDate: nextDate,
          quantityKg: nextQty,
          pricePerKg: nextPrice,
          totalAmount: nextTotal,
          notes: nextNotes,
          clearNotes: nextNotes == null,
          updatedAt: now,
        );

        // 2. ALL WRITES AFTER READS
        tx.update(orderRef, <String, dynamic>{
          'inventory_id': next.inventoryId,
          'abaca_type': next.abacaType,
          'order_date': FirestoreHelpers.toDateOnlyTimestamp(next.orderDate),
          'quantity_kg': next.quantityKg,
          'price_per_kg': next.pricePerKg,
          'total_amount': next.totalAmount,
          'notes': next.notes,
          'updated_at': FirestoreHelpers.toTimestamp(now),
        });

        FirestoreAuditRepository.setAuditInTransaction(
          tx,
          _firestore,
          actorEmployeeId: actorEmployeeId,
          action: AuditAction.updated,
          entityType: AuditEntityType.order,
          entityId: orderId,
          description: 'Updated pending order $orderId.',
          timestamp: now,
        );
        return next;
      });

      return Ok<Order>(updated);
    } catch (error) {
      return Err<Order>(
        FirestoreHelpers.mapError(error, entityName: 'Order', entityId: orderId),
      );
    }
  }

  @override
  Future<Result<void>> deleteOrder(
    String id, {
    String? actorEmployeeId,
  }) async {
    try {
      final orderRef = _orders.doc(id);
      final orderSnap = await orderRef.get();
      if (!orderSnap.exists || orderSnap.data() == null) {
        return Err<void>(
          NotFoundFailure(
            entityName: 'Order',
            entityId: id,
            message: 'Order $id was not found.',
          ),
        );
      }

      final paymentsSnap = await orderRef
          .collection(FirestoreCollections.paymentsSubcollection)
          .limit(1)
          .get();
      if (paymentsSnap.docs.isNotEmpty) {
        return const Err<void>(
          ConflictFailure(
            message:
                'Cannot delete order with existing payments. Void payments first.',
            code: 'foreign_key_violation',
          ),
        );
      }

      final deliveriesSnap = await _firestore
          .collection(FirestoreCollections.deliveries)
          .where('order_id', isEqualTo: id)
          .limit(1)
          .get();
      if (deliveriesSnap.docs.isNotEmpty) {
        return const Err<void>(
          ConflictFailure(
            message: 'Cannot delete order that has a delivery record.',
            code: 'foreign_key_violation',
          ),
        );
      }

      // Mirror ON DELETE SET NULL on stock_ins.order_id.
      final linkedStockIns = await _firestore
          .collection(FirestoreCollections.stockIns)
          .where('order_id', isEqualTo: id)
          .get();

      final batch = _firestore.batch();
      for (final stockInDoc in linkedStockIns.docs) {
        batch.update(stockInDoc.reference, <String, dynamic>{'order_id': null});
      }
      batch.delete(orderRef);
      FirestoreAuditRepository.setAuditInBatch(
        batch,
        _firestore,
        actorEmployeeId: actorEmployeeId,
        action: AuditAction.deleted,
        entityType: AuditEntityType.order,
        entityId: id,
        description: 'Deleted order $id.',
      );
      await batch.commit();
      return const Ok<void>(null);
    } catch (error) {
      return Err<void>(
        FirestoreHelpers.mapError(error, entityName: 'Order', entityId: id),
      );
    }
  }
}
