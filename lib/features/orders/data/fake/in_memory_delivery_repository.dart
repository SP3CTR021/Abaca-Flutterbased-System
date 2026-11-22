import '../../../../core/data/fake/in_memory_database.dart';
import '../../../../core/data/input_validators.dart';
import '../../../../core/errors/app_failure.dart';
import '../../../../core/result/result.dart';
import '../../../../core/types/query_filters.dart';
import '../../../../core/utils/decimal_precision.dart';
import '../../../audit/domain/entities/audit_enums.dart';
import '../../../inventory/domain/entities/stock_out.dart';
import '../../../inventory/domain/entities/stock_out_reason.dart';
import '../../domain/entities/delivery.dart';
import '../../domain/entities/delivery_status.dart';
import '../../domain/entities/order_status.dart';
import '../../domain/repositories/delivery_repository.dart';

/// Pure-Dart in-memory implementation of [DeliveryRepository].
final class InMemoryDeliveryRepository implements DeliveryRepository {
  InMemoryDeliveryRepository(this._db);

  final InMemoryDatabase _db;

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

    final order = _db.orders[orderId];
    if (order == null) {
      return Err<Delivery>(
        NotFoundFailure(
          entityName: 'Order',
          entityId: orderId,
          message: 'Order $orderId was not found.',
        ),
      );
    }
    if (!_db.employees.containsKey(employeeId)) {
      return Err<Delivery>(
        NotFoundFailure(
          entityName: 'Employee',
          entityId: employeeId,
          message: 'Employee $employeeId was not found.',
        ),
      );
    }
    if (order.status != OrderStatus.stocked) {
      return Err<Delivery>(
        InvalidStateTransitionFailure(
          entityName: 'Order',
          currentState: order.status.dbValue,
          attemptedAction: 'schedule_delivery',
          message: 'Deliveries can only be scheduled for stocked orders.',
        ),
      );
    }

    final duplicate = _db.deliveries.values.any((d) => d.orderId == orderId);
    if (duplicate) {
      return Err<Delivery>(
        ConflictFailure(
          message: 'A delivery is already scheduled for order $orderId.',
          code: 'unique_violation',
        ),
      );
    }

    final now = _db.nextTimestamp();
    final dateOnly =
        DateTime(deliveryDate.year, deliveryDate.month, deliveryDate.day);
    final trimmedNotes = notes?.trim();
    final created = Delivery(
      id: _db.nextId(),
      orderId: orderId,
      employeeId: employeeId,
      deliveryDate: dateOnly,
      status: DeliveryStatus.pending,
      notes:
          (trimmedNotes == null || trimmedNotes.isEmpty) ? null : trimmedNotes,
      createdAt: now,
      updatedAt: now,
    );

    _db.deliveries[created.id] = created;
    _db.recordAudit(
      actorEmployeeId: actorEmployeeId ?? employeeId,
      action: AuditAction.created,
      entityType: AuditEntityType.delivery,
      entityId: created.id,
      description: 'Scheduled delivery for order $orderId.',
      createdAt: now,
    );
    _db.notify();
    return Ok<Delivery>(created);
  }

  @override
  Future<Result<Delivery>> completeDelivery({
    required String deliveryId,
    required String actorEmployeeId,
    DateTime? deliveredAt,
    String? notes,
  }) async {
    final delivery = _db.deliveries[deliveryId];
    if (delivery == null) {
      return Err<Delivery>(
        NotFoundFailure(
          entityName: 'Delivery',
          entityId: deliveryId,
          message: 'Delivery $deliveryId was not found.',
        ),
      );
    }
    if (delivery.status != DeliveryStatus.pending) {
      return Err<Delivery>(
        InvalidStateTransitionFailure(
          entityName: 'Delivery',
          currentState: delivery.status.dbValue,
          attemptedAction: 'complete_delivery',
          message:
              'Delivery $deliveryId is already ${delivery.status.dbValue}.',
        ),
      );
    }

    final order = _db.orders[delivery.orderId];
    if (order == null) {
      return Err<Delivery>(
        NotFoundFailure(
          entityName: 'Order',
          entityId: delivery.orderId,
          message: 'Order ${delivery.orderId} was not found.',
        ),
      );
    }
    if (order.status != OrderStatus.stocked) {
      return Err<Delivery>(
        InvalidStateTransitionFailure(
          entityName: 'Order',
          currentState: order.status.dbValue,
          attemptedAction: 'complete_delivery',
          message:
              'Order must be in stocked state before completing delivery (current: ${order.status.dbValue}).',
        ),
      );
    }

    final inv = _db.inventory[order.inventoryId]!;
    if (DecimalPrecision.compare2(inv.currentStockKg, order.quantityKg) < 0) {
      return Err<Delivery>(
        InsufficientStockFailure(
          abacaType: inv.abacaType,
          availableKg: inv.currentStockKg,
          requestedKg: order.quantityKg,
          message: 'Insufficient ${inv.abacaType} stock to complete delivery.',
        ),
      );
    }

    final now = _db.nextTimestamp();
    final effectiveDeliveredAt = (deliveredAt ?? now).toUtc();
    final trimmedNotes = notes?.trim();
    final nextNotes = (trimmedNotes == null || trimmedNotes.isEmpty)
        ? delivery.notes
        : trimmedNotes;

    // Single atomic deduction + linked StockOut + Delivery/Order sync.
    _db.inventory[inv.id] = inv.copyWith(
      currentStockKg:
          DecimalPrecision.subtract2(inv.currentStockKg, order.quantityKg),
      lastUpdated: now,
    );

    final stockOut = StockOut(
      id: _db.nextId(),
      inventoryId: inv.id,
      employeeId: actorEmployeeId,
      deliveryId: delivery.id,
      orderId: order.id,
      quantityKg: order.quantityKg,
      reason: StockOutReason.released,
      notes: nextNotes ?? 'Auto-released on delivery completion.',
      date: DateTime(
        effectiveDeliveredAt.year,
        effectiveDeliveredAt.month,
        effectiveDeliveredAt.day,
      ),
      createdAt: now,
      updatedAt: now,
    );
    _db.stockOuts[stockOut.id] = stockOut;

    final updatedDelivery = delivery.copyWith(
      status: DeliveryStatus.delivered,
      deliveredAt: effectiveDeliveredAt,
      notes: nextNotes,
      clearNotes: nextNotes == null,
      updatedAt: now,
    );
    _db.deliveries[delivery.id] = updatedDelivery;

    _db.orders[order.id] = order.copyWith(
      status: OrderStatus.delivered,
      updatedAt: now,
    );

    _db.recordAudit(
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
      createdAt: now,
    );
    _db.notify();
    return Ok<Delivery>(updatedDelivery);
  }

  @override
  Future<Result<Delivery>> getDeliveryById(String id) async {
    final delivery = _db.deliveries[id];
    if (delivery == null) {
      return Err<Delivery>(
        NotFoundFailure(
          entityName: 'Delivery',
          entityId: id,
          message: 'Delivery $id was not found.',
        ),
      );
    }
    return Ok<Delivery>(delivery);
  }

  @override
  Future<Result<Delivery?>> getDeliveryByOrderId(String orderId) async {
    for (final delivery in _db.deliveries.values) {
      if (delivery.orderId == orderId) {
        return Ok<Delivery?>(delivery);
      }
    }
    return const Ok<Delivery?>(null);
  }

  @override
  Future<Result<List<Delivery>>> getDeliveries({
    String? employeeId,
    DeliveryStatus? status,
    DateRangeFilter? dateRange,
  }) async {
    final rangeFailure = InputValidators.validateDateRange(dateRange);
    if (rangeFailure != null) return Err<List<Delivery>>(rangeFailure);

    return Ok<List<Delivery>>(
      _filterDeliveries(
        employeeId: employeeId,
        status: status,
        dateRange: dateRange,
        ascending: false,
      ),
    );
  }

  @override
  Stream<List<Delivery>> watchDeliveries({
    String? employeeId,
    DeliveryStatus? status,
  }) =>
      _db.watch(
        () => _filterDeliveries(
          employeeId: employeeId,
          status: status,
          ascending: true,
        ),
      );

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

    final current = _db.deliveries[deliveryId];
    if (current == null) {
      return Err<Delivery>(
        NotFoundFailure(
          entityName: 'Delivery',
          entityId: deliveryId,
          message: 'Delivery $deliveryId was not found.',
        ),
      );
    }
    if (current.status != DeliveryStatus.pending) {
      return Err<Delivery>(
        InvalidStateTransitionFailure(
          entityName: 'Delivery',
          currentState: current.status.dbValue,
          attemptedAction: 'reassign_delivery',
          message: 'Completed deliveries cannot be reassigned.',
        ),
      );
    }
    if (!_db.employees.containsKey(newEmployeeId)) {
      return Err<Delivery>(
        NotFoundFailure(
          entityName: 'Employee',
          entityId: newEmployeeId,
          message: 'Employee $newEmployeeId was not found.',
        ),
      );
    }

    final now = _db.nextTimestamp();
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

    final updated = current.copyWith(
      employeeId: newEmployeeId,
      deliveryDate: nextDate,
      notes: nextNotes,
      clearNotes: nextNotes == null,
      updatedAt: now,
    );
    _db.deliveries[deliveryId] = updated;
    _db.recordAudit(
      actorEmployeeId: actorEmployeeId,
      action: AuditAction.updated,
      entityType: AuditEntityType.delivery,
      entityId: deliveryId,
      description: 'Reassigned delivery $deliveryId to $newEmployeeId.',
      createdAt: now,
    );
    _db.notify();
    return Ok<Delivery>(updated);
  }

  List<Delivery> _filterDeliveries({
    String? employeeId,
    DeliveryStatus? status,
    DateRangeFilter? dateRange,
    required bool ascending,
  }) {
    final list = _db.deliveries.values.where((delivery) {
      if (employeeId != null && delivery.employeeId != employeeId) return false;
      if (status != null && delivery.status != status) return false;
      if (dateRange != null && !dateRange.contains(delivery.deliveryDate)) {
        return false;
      }
      return true;
    }).toList()
      ..sort(
        (a, b) => ascending
            ? a.deliveryDate.compareTo(b.deliveryDate)
            : b.deliveryDate.compareTo(a.deliveryDate),
      );
    return List<Delivery>.unmodifiable(list);
  }
}
