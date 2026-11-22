import '../../../../core/result/result.dart';
import '../../../../core/types/query_filters.dart';
import '../entities/order.dart';
import '../entities/order_status.dart';

/// Manages customer abaca orders (`orders` table / `orders` root collection).
abstract interface class OrderRepository {
  /// Creates a new [Order] in [OrderStatus.pending] status.
  ///
  /// Resolves `abacaType` from [inventoryId] so the snapshot stays authoritative
  /// and computes `totalAmount = DecimalPrecision.multiply2(quantityKg, pricePerKg)`.
  Future<Result<Order>> createOrder({
    required String customerId,
    required String employeeId,
    required String inventoryId,
    required DateTime orderDate,
    required double quantityKg,
    required double pricePerKg,
    String? notes,
  });

  /// Fetches an [Order] by [id].
  Future<Result<Order>> getOrderById(String id);

  /// Fetches an [Order] alongside customer/employee names, 1:1 [Delivery],
  /// and all recorded [Payment]s.
  Future<Result<OrderWithDetails>> getOrderWithDetails(String id);

  /// Queries orders filtered by customer, creator employee, fiber grade,
  /// lifecycle [status], and/or [dateRange].
  Future<Result<List<Order>>> getOrders({
    String? customerId,
    String? employeeId,
    String? inventoryId,
    OrderStatus? status,
    DateRangeFilter? dateRange,
  });

  /// Real-time stream of orders optionally filtered by [customerId] or [status].
  Stream<List<Order>> watchOrders({
    String? customerId,
    OrderStatus? status,
  });

  /// Transitions a `pending` order to `stocked` after verifying sufficient
  /// `inventory.current_stock_kg` without deducting stock yet.
  Future<Result<Order>> markOrderStocked({
    required String orderId,
    required String actorEmployeeId,
  });

  /// Transitions a `pending` or `stocked` order (without a completed delivery)
  /// to `cancelled` and logs a `statusChanged` audit entry.
  Future<Result<Order>> cancelOrder({
    required String orderId,
    required String actorEmployeeId,
    String? reason,
  });

  /// Updates mutable fields on an order while it is still `pending`.
  Future<Result<Order>> updatePendingOrder({
    required String orderId,
    String? inventoryId,
    double? quantityKg,
    double? pricePerKg,
    DateTime? orderDate,
    String? notes,
    bool clearNotes = false,
    required String actorEmployeeId,
  });

  /// Deletes an order only if no payments or deliveries block deletion
  /// (`ConflictFailure` if payments or a delivery exist; any linked `stock_ins.order_id`
  /// is nullified via `ON DELETE SET NULL`).
  Future<Result<void>> deleteOrder(
    String id, {
    String? actorEmployeeId,
  });
}
