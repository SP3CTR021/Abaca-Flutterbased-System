import '../../../../core/data/fake/in_memory_database.dart';
import '../../../../core/data/input_validators.dart';
import '../../../../core/errors/app_failure.dart';
import '../../../../core/result/result.dart';
import '../../../../core/types/query_filters.dart';
import '../../../../core/utils/decimal_precision.dart';
import '../../../audit/domain/entities/audit_enums.dart';
import '../../domain/entities/delivery.dart';
import '../../domain/entities/delivery_status.dart';
import '../../domain/entities/order.dart';
import '../../domain/entities/order_status.dart';
import '../../domain/repositories/order_repository.dart';

/// Pure-Dart in-memory implementation of [OrderRepository].
final class InMemoryOrderRepository implements OrderRepository {
  InMemoryOrderRepository(this._db);

  final InMemoryDatabase _db;

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

    if (!_db.customers.containsKey(customerId)) {
      return Err<Order>(
        NotFoundFailure(
          entityName: 'Customer',
          entityId: customerId,
          message: 'Customer $customerId was not found.',
        ),
      );
    }
    if (!_db.employees.containsKey(employeeId)) {
      return Err<Order>(
        NotFoundFailure(
          entityName: 'Employee',
          entityId: employeeId,
          message: 'Employee $employeeId was not found.',
        ),
      );
    }
    final inv = _db.inventory[inventoryId];
    if (inv == null) {
      return Err<Order>(
        NotFoundFailure(
          entityName: 'Inventory',
          entityId: inventoryId,
          message: 'Inventory grade $inventoryId was not found.',
        ),
      );
    }

    final now = _db.nextTimestamp();
    final dateOnly = DateTime(orderDate.year, orderDate.month, orderDate.day);
    final qty = DecimalPrecision.round2(quantityKg);
    final price = DecimalPrecision.round2(pricePerKg);
    final total = DecimalPrecision.multiply2(qty, price);
    final trimmedNotes = notes?.trim();

    final created = Order(
      id: _db.nextId(),
      customerId: customerId,
      employeeId: employeeId,
      inventoryId: inventoryId,
      abacaType: inv.abacaType,
      orderDate: dateOnly,
      quantityKg: qty,
      pricePerKg: price,
      totalAmount: total,
      status: OrderStatus.pending,
      notes:
          (trimmedNotes == null || trimmedNotes.isEmpty) ? null : trimmedNotes,
      createdAt: now,
      updatedAt: now,
    );

    _db.orders[created.id] = created;
    _db.recordAudit(
      actorEmployeeId: employeeId,
      action: AuditAction.created,
      entityType: AuditEntityType.order,
      entityId: created.id,
      description:
          'Created order for ${created.quantityKg} kg of ${created.abacaType}.',
      newValues: <String, Object?>{
        'customer_id': created.customerId,
        'inventory_id': created.inventoryId,
        'quantity_kg': created.quantityKg,
        'total_amount': created.totalAmount,
      },
      createdAt: now,
    );
    _db.notify();
    return Ok<Order>(created);
  }

  @override
  Future<Result<Order>> getOrderById(String id) async {
    final order = _db.orders[id];
    if (order == null) {
      return Err<Order>(
        NotFoundFailure(
          entityName: 'Order',
          entityId: id,
          message: 'Order $id was not found.',
        ),
      );
    }
    return Ok<Order>(order);
  }

  @override
  Future<Result<OrderWithDetails>> getOrderWithDetails(String id) async {
    final order = _db.orders[id];
    if (order == null) {
      return Err<OrderWithDetails>(
        NotFoundFailure(
          entityName: 'Order',
          entityId: id,
          message: 'Order $id was not found.',
        ),
      );
    }

    Delivery? delivery;
    for (final d in _db.deliveries.values) {
      if (d.orderId == id) {
        delivery = d;
        break;
      }
    }

    final payments = _db.payments.values
        .where((p) => p.orderId == id)
        .toList()
      ..sort((a, b) => a.paymentDate.compareTo(b.paymentDate));

    return Ok<OrderWithDetails>(
      OrderWithDetails(
        order: order,
        customerName: _db.customers[order.customerId]?.fullName,
        employeeName: _db.employees[order.employeeId]?.fullName,
        delivery: delivery,
        payments: payments,
      ),
    );
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

    return Ok<List<Order>>(
      _filterOrders(
        customerId: customerId,
        employeeId: employeeId,
        inventoryId: inventoryId,
        status: status,
        dateRange: dateRange,
      ),
    );
  }

  @override
  Stream<List<Order>> watchOrders({
    String? customerId,
    OrderStatus? status,
  }) =>
      _db.watch(() => _filterOrders(customerId: customerId, status: status));

  @override
  Future<Result<Order>> markOrderStocked({
    required String orderId,
    required String actorEmployeeId,
  }) async {
    final order = _db.orders[orderId];
    if (order == null) {
      return Err<Order>(
        NotFoundFailure(
          entityName: 'Order',
          entityId: orderId,
          message: 'Order $orderId was not found.',
        ),
      );
    }
    if (order.status != OrderStatus.pending) {
      return Err<Order>(
        InvalidStateTransitionFailure(
          entityName: 'Order',
          currentState: order.status.dbValue,
          attemptedAction: 'mark_order_stocked',
          message: 'Only pending orders can be marked stocked.',
        ),
      );
    }

    final inv = _db.inventory[order.inventoryId]!;
    if (DecimalPrecision.compare2(inv.currentStockKg, order.quantityKg) < 0) {
      return Err<Order>(
        InsufficientStockFailure(
          abacaType: inv.abacaType,
          availableKg: inv.currentStockKg,
          requestedKg: order.quantityKg,
          message: 'Insufficient ${inv.abacaType} stock to mark order stocked.',
        ),
      );
    }

    final now = _db.nextTimestamp();
    final updated = order.copyWith(status: OrderStatus.stocked, updatedAt: now);
    _db.orders[orderId] = updated;
    _db.recordAudit(
      actorEmployeeId: actorEmployeeId,
      action: AuditAction.statusChanged,
      entityType: AuditEntityType.order,
      entityId: orderId,
      description: 'Marked order as stocked.',
      oldValues: <String, Object?>{'status': order.status.dbValue},
      newValues: <String, Object?>{'status': updated.status.dbValue},
      createdAt: now,
    );
    _db.notify();
    return Ok<Order>(updated);
  }

  @override
  Future<Result<Order>> cancelOrder({
    required String orderId,
    required String actorEmployeeId,
    String? reason,
  }) async {
    final order = _db.orders[orderId];
    if (order == null) {
      return Err<Order>(
        NotFoundFailure(
          entityName: 'Order',
          entityId: orderId,
          message: 'Order $orderId was not found.',
        ),
      );
    }
    if (order.status == OrderStatus.delivered ||
        order.status == OrderStatus.cancelled) {
      return Err<Order>(
        InvalidStateTransitionFailure(
          entityName: 'Order',
          currentState: order.status.dbValue,
          attemptedAction: 'cancel_order',
          message: 'Cannot cancel order in status ${order.status.dbValue}.',
        ),
      );
    }

    final hasPayments = _db.payments.values.any((p) => p.orderId == orderId);
    if (hasPayments) {
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

    String? pendingDeliveryId;
    for (final entry in _db.deliveries.entries) {
      if (entry.value.orderId == orderId) {
        if (entry.value.status == DeliveryStatus.delivered) {
          return const Err<Order>(
            InvalidStateTransitionFailure(
              entityName: 'Order',
              currentState: 'delivered',
              attemptedAction: 'cancel_order',
              message:
                  'Cannot cancel an order whose delivery is already delivered.',
            ),
          );
        }
        pendingDeliveryId = entry.key;
        break;
      }
    }

    if (pendingDeliveryId != null) {
      _db.deliveries.remove(pendingDeliveryId);
    }

    final now = _db.nextTimestamp();
    final trimmedReason = reason?.trim();
    var nextNotes = order.notes;
    if (trimmedReason != null && trimmedReason.isNotEmpty) {
      nextNotes = nextNotes == null || nextNotes.isEmpty
          ? '[Cancelled] $trimmedReason'
          : '$nextNotes\n[Cancelled] $trimmedReason';
    }

    final updated = order.copyWith(
      status: OrderStatus.cancelled,
      notes: nextNotes,
      clearNotes: nextNotes == null,
      updatedAt: now,
    );
    _db.orders[orderId] = updated;
    _db.recordAudit(
      actorEmployeeId: actorEmployeeId,
      action: AuditAction.statusChanged,
      entityType: AuditEntityType.order,
      entityId: orderId,
      description: (trimmedReason != null && trimmedReason.isNotEmpty)
          ? trimmedReason
          : 'Order cancelled.',
      oldValues: <String, Object?>{'status': order.status.dbValue},
      newValues: <String, Object?>{'status': updated.status.dbValue},
      createdAt: now,
    );
    _db.notify();
    return Ok<Order>(updated);
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

    final current = _db.orders[orderId];
    if (current == null) {
      return Err<Order>(
        NotFoundFailure(
          entityName: 'Order',
          entityId: orderId,
          message: 'Order $orderId was not found.',
        ),
      );
    }
    if (current.status != OrderStatus.pending) {
      return Err<Order>(
        InvalidStateTransitionFailure(
          entityName: 'Order',
          currentState: current.status.dbValue,
          attemptedAction: 'update_pending_order',
          message: 'Only pending orders can be edited.',
        ),
      );
    }

    var nextInvId = current.inventoryId;
    var nextAbacaType = current.abacaType;
    if (inventoryId != null && inventoryId != current.inventoryId) {
      final inv = _db.inventory[inventoryId];
      if (inv == null) {
        return Err<Order>(
          NotFoundFailure(
            entityName: 'Inventory',
            entityId: inventoryId,
            message: 'Inventory grade $inventoryId was not found.',
          ),
        );
      }
      nextInvId = inv.id;
      nextAbacaType = inv.abacaType;
    }

    final now = _db.nextTimestamp();
    final nextQty = DecimalPrecision.round2(quantityKg ?? current.quantityKg);
    final nextPrice = DecimalPrecision.round2(pricePerKg ?? current.pricePerKg);
    final nextTotal = DecimalPrecision.multiply2(nextQty, nextPrice);
    final nextDate = orderDate != null
        ? DateTime(orderDate.year, orderDate.month, orderDate.day)
        : current.orderDate;
    final nextNotes = clearNotes
        ? null
        : (notes != null
            ? (notes.trim().isEmpty ? null : notes.trim())
            : current.notes);

    final updated = current.copyWith(
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

    _db.orders[orderId] = updated;
    _db.recordAudit(
      actorEmployeeId: actorEmployeeId,
      action: AuditAction.updated,
      entityType: AuditEntityType.order,
      entityId: orderId,
      description: 'Updated pending order $orderId.',
      createdAt: now,
    );
    _db.notify();
    return Ok<Order>(updated);
  }

  @override
  Future<Result<void>> deleteOrder(
    String id, {
    String? actorEmployeeId,
  }) async {
    final existing = _db.orders[id];
    if (existing == null) {
      return Err<void>(
        NotFoundFailure(
          entityName: 'Order',
          entityId: id,
          message: 'Order $id was not found.',
        ),
      );
    }

    if (_db.payments.values.any((p) => p.orderId == id)) {
      return const Err<void>(
        ConflictFailure(
          message:
              'Cannot delete order with existing payments. Void payments first.',
          code: 'foreign_key_violation',
        ),
      );
    }
    if (_db.deliveries.values.any((d) => d.orderId == id)) {
      return const Err<void>(
        ConflictFailure(
          message: 'Cannot delete order that has a delivery record.',
          code: 'foreign_key_violation',
        ),
      );
    }

    // Mirror ON DELETE SET NULL on stock_ins.order_id.
    for (final entry in _db.stockIns.entries.toList(growable: false)) {
      if (entry.value.orderId == id) {
        _db.stockIns[entry.key] = entry.value.copyWith(clearOrderId: true);
      }
    }

    _db.orders.remove(id);
    _db.recordAudit(
      actorEmployeeId: actorEmployeeId,
      action: AuditAction.deleted,
      entityType: AuditEntityType.order,
      entityId: id,
      description: 'Deleted order $id.',
    );
    _db.notify();
    return const Ok<void>(null);
  }

  List<Order> _filterOrders({
    String? customerId,
    String? employeeId,
    String? inventoryId,
    OrderStatus? status,
    DateRangeFilter? dateRange,
  }) {
    final list = _db.orders.values.where((order) {
      if (customerId != null && order.customerId != customerId) return false;
      if (employeeId != null && order.employeeId != employeeId) return false;
      if (inventoryId != null && order.inventoryId != inventoryId) return false;
      if (status != null && order.status != status) return false;
      if (dateRange != null && !dateRange.contains(order.orderDate)) {
        return false;
      }
      return true;
    }).toList()
      ..sort((a, b) {
        final dateCmp = b.orderDate.compareTo(a.orderDate);
        return dateCmp != 0 ? dateCmp : b.createdAt.compareTo(a.createdAt);
      });
    return List<Order>.unmodifiable(list);
  }
}
