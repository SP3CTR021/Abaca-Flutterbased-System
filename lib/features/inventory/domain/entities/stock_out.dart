import 'package:meta/meta.dart';

import '../../../../core/utils/decimal_precision.dart';
import 'stock_out_reason.dart';

/// Outbound stock movement (`stock_outs` table / root collection).
///
/// Relationships:
/// - `N:1` child of `inventory` (`stock_outs.inventory_id`, `ON DELETE RESTRICT`).
/// - `N:1` child of `employees` (`stock_outs.employee_id`, `ON DELETE RESTRICT`).
/// - `0..1:1` optional link to `deliveries` (`stock_outs.delivery_id`, `UNIQUE`,
///   `ON DELETE RESTRICT`) created atomically by `DeliveryRepository.completeDelivery`
///   to trace `released` deliveries and prevent double-deduction.
/// - `N:1` optional link to `orders` (`stock_outs.order_id`, `ON DELETE RESTRICT`).
@immutable
final class StockOut {
  const StockOut({
    required this.id,
    required this.inventoryId,
    required this.employeeId,
    this.deliveryId,
    this.orderId,
    required this.quantityKg,
    required this.reason,
    this.notes,
    required this.date,
    required this.createdAt,
    required this.updatedAt,
  });

  /// Primary key (`stockout_id`).
  final String id;
  final String inventoryId;
  final String employeeId;

  /// Unique link to the fulfilling [Delivery] when [reason] is [StockOutReason.released].
  final String? deliveryId;

  /// Optional link to the originating [Order] for delivery-released stock.
  final String? orderId;
  final double quantityKg;
  final StockOutReason reason;
  final String? notes;
  final DateTime date;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// `true` when this deduction was generated automatically by a delivery.
  bool get isDeliveryLinked => deliveryId != null;

  StockOut copyWith({
    String? id,
    String? inventoryId,
    String? employeeId,
    String? deliveryId,
    bool clearDeliveryId = false,
    String? orderId,
    bool clearOrderId = false,
    double? quantityKg,
    StockOutReason? reason,
    String? notes,
    bool clearNotes = false,
    DateTime? date,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) =>
      StockOut(
        id: id ?? this.id,
        inventoryId: inventoryId ?? this.inventoryId,
        employeeId: employeeId ?? this.employeeId,
        deliveryId: clearDeliveryId ? null : (deliveryId ?? this.deliveryId),
        orderId: clearOrderId ? null : (orderId ?? this.orderId),
        quantityKg: quantityKg ?? this.quantityKg,
        reason: reason ?? this.reason,
        notes: clearNotes ? null : (notes ?? this.notes),
        date: date ?? this.date,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StockOut &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          inventoryId == other.inventoryId &&
          employeeId == other.employeeId &&
          deliveryId == other.deliveryId &&
          orderId == other.orderId &&
          DecimalPrecision.equals2(quantityKg, other.quantityKg) &&
          reason == other.reason &&
          notes == other.notes &&
          date == other.date &&
          createdAt == other.createdAt &&
          updatedAt == other.updatedAt;

  @override
  int get hashCode => Object.hash(
        runtimeType,
        id,
        inventoryId,
        employeeId,
        deliveryId,
        orderId,
        DecimalPrecision.toMinorUnits(quantityKg),
        reason,
        notes,
        date,
        createdAt,
        updatedAt,
      );

  @override
  String toString() =>
      'StockOut(id: $id, inventoryId: $inventoryId, quantityKg: $quantityKg, reason: ${reason.dbValue})';
}
