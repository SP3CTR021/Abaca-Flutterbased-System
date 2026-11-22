import 'package:meta/meta.dart';

import 'delivery_status.dart';

/// Order dispatch & fulfillment record (`deliveries` table / root collection).
///
/// Relationships:
/// - `1:1` child of `orders` (`deliveries.order_id` `UNIQUE`, `ON DELETE RESTRICT`
///   when delivered; delete scheduled pending delivery before deleting order).
/// - `N:1` child of `employees` (`deliveries.employee_id`, `ON DELETE RESTRICT`).
/// - `1:0..1` parent of `stock_outs` (`stock_outs.delivery_id`, `UNIQUE`).
///
/// Backend mapping note:
/// - Stored as a top-level collection in Firestore (not an order subcollection)
///   so drivers can stream assigned deliveries directly. Strict `1:1` per order
///   is enforced atomically via lock document `order_delivery_locks/{orderId}`.
@immutable
final class Delivery {
  const Delivery({
    required this.id,
    required this.orderId,
    required this.employeeId,
    required this.deliveryDate,
    this.deliveredAt,
    required this.status,
    this.notes,
    required this.createdAt,
    required this.updatedAt,
  });

  /// Primary key (`delivery_id`).
  final String id;

  /// Unique 1:1 FK referencing `orders.order_id`.
  final String orderId;

  /// Assigned driver/handler FK referencing `employees.employee_id`.
  final String employeeId;
  final DateTime deliveryDate;

  /// Actual completion timestamp populated when `status` transitions to `delivered`.
  final DateTime? deliveredAt;
  final DeliveryStatus status;
  final String? notes;
  final DateTime createdAt;
  final DateTime updatedAt;

  Delivery copyWith({
    String? id,
    String? orderId,
    String? employeeId,
    DateTime? deliveryDate,
    DateTime? deliveredAt,
    bool clearDeliveredAt = false,
    DeliveryStatus? status,
    String? notes,
    bool clearNotes = false,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) =>
      Delivery(
        id: id ?? this.id,
        orderId: orderId ?? this.orderId,
        employeeId: employeeId ?? this.employeeId,
        deliveryDate: deliveryDate ?? this.deliveryDate,
        deliveredAt:
            clearDeliveredAt ? null : (deliveredAt ?? this.deliveredAt),
        status: status ?? this.status,
        notes: clearNotes ? null : (notes ?? this.notes),
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Delivery &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          orderId == other.orderId &&
          employeeId == other.employeeId &&
          deliveryDate == other.deliveryDate &&
          deliveredAt == other.deliveredAt &&
          status == other.status &&
          notes == other.notes &&
          createdAt == other.createdAt &&
          updatedAt == other.updatedAt;

  @override
  int get hashCode => Object.hash(
        runtimeType,
        id,
        orderId,
        employeeId,
        deliveryDate,
        deliveredAt,
        status,
        notes,
        createdAt,
        updatedAt,
      );

  @override
  String toString() =>
      'Delivery(id: $id, orderId: $orderId, employeeId: $employeeId, status: ${status.dbValue})';
}
