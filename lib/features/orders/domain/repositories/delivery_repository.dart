import '../../../../core/result/result.dart';
import '../../../../core/types/query_filters.dart';
import '../entities/delivery.dart';
import '../entities/delivery_status.dart';

/// Manages 1:1 order dispatches and atomic delivery fulfillment (`deliveries`).
abstract interface class DeliveryRepository {
  /// Schedules a pending [Delivery] for a `stocked` order without an existing
  /// delivery (`1:1` enforced via `UNIQUE(order_id)` in Postgres and
  /// `order_delivery_locks/{orderId}` in Firestore).
  Future<Result<Delivery>> scheduleDelivery({
    required String orderId,
    required String employeeId,
    required DateTime deliveryDate,
    String? notes,
    String? actorEmployeeId,
  });

  /// Atomically completes a scheduled delivery (single source of truth that
  /// eliminates the legacy PHP + MySQL trigger double-deduction bug):
  /// 1. Validates `delivery.status == pending` and `order.status == stocked`.
  /// 2. Checks `inventory.current_stock_kg >= order.quantity_kg`.
  /// 3. Decrements `inventory.current_stock_kg` once.
  /// 4. Creates a linked `StockOut(reason: released, deliveryId, orderId)`.
  /// 5. Marks `deliveries.status = delivered` (+ `deliveredAt`) and
  ///    `orders.status = delivered`.
  /// 6. Writes a `deliveryCompleted` audit log entry.
  Future<Result<Delivery>> completeDelivery({
    required String deliveryId,
    required String actorEmployeeId,
    DateTime? deliveredAt,
    String? notes,
  });

  /// Fetches a [Delivery] by [id].
  Future<Result<Delivery>> getDeliveryById(String id);

  /// Fetches the 1:1 [Delivery] for [orderId], or `null` if not yet scheduled.
  Future<Result<Delivery?>> getDeliveryByOrderId(String orderId);

  /// Queries deliveries optionally filtered by assigned driver, [status],
  /// and/or [dateRange].
  Future<Result<List<Delivery>>> getDeliveries({
    String? employeeId,
    DeliveryStatus? status,
    DateRangeFilter? dateRange,
  });

  /// Real-time stream of deliveries (e.g. driver's pending dispatch queue).
  Stream<List<Delivery>> watchDeliveries({
    String? employeeId,
    DeliveryStatus? status,
  });

  /// Reassigns a `pending` delivery to another employee/date.
  Future<Result<Delivery>> reassignDelivery({
    required String deliveryId,
    required String newEmployeeId,
    DateTime? newDeliveryDate,
    String? notes,
    required String actorEmployeeId,
  });
}
