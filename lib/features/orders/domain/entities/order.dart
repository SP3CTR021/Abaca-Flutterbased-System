import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import '../../../../core/utils/decimal_precision.dart';
import '../../../finance/domain/entities/payment.dart';
import 'delivery.dart';
import 'order_status.dart';

/// Customer purchase order for an abaca fiber grade (`orders` table / collection).
///
/// Relationships:
/// - `N:1` child of `customers` (`orders.customer_id`, `ON DELETE RESTRICT`).
/// - `N:1` child of `employees` (`orders.employee_id`, `ON DELETE RESTRICT`).
/// - `N:1` child of `inventory` via added `inventory_id` FK (`ON DELETE RESTRICT`)
///   paired with `abaca_type` snapshot (`ON UPDATE CASCADE`), enabling ID-based
///   lookups inside Firestore `runTransaction`.
/// - `1:0..N` parent of `stock_ins` (`stock_ins.order_id`, `ON DELETE SET NULL`).
/// - `1:0..1` parent of `deliveries` (`deliveries.order_id` `UNIQUE`).
/// - `1:N` parent of `payments` (`payments.order_id`).
@immutable
final class Order {
  const Order({
    required this.id,
    required this.customerId,
    required this.employeeId,
    required this.inventoryId,
    required this.abacaType,
    required this.orderDate,
    required this.quantityKg,
    required this.pricePerKg,
    required this.totalAmount,
    required this.status,
    this.notes,
    required this.createdAt,
    required this.updatedAt,
  });

  /// Primary key (`order_id`).
  final String id;
  final String customerId;
  final String employeeId;

  /// Normalized FK to `inventory.inventory_id` (fixes unreferenced string link).
  final String inventoryId;

  /// Snapshot of `inventory.abaca_type` at order time (`ON UPDATE CASCADE` in SQL).
  final String abacaType;
  final DateTime orderDate;
  final double quantityKg;
  final double pricePerKg;

  /// Computed order total (`quantityKg * pricePerKg` rounded to 2 decimals).
  final double totalAmount;
  final OrderStatus status;
  final String? notes;
  final DateTime createdAt;
  final DateTime updatedAt;

  Order copyWith({
    String? id,
    String? customerId,
    String? employeeId,
    String? inventoryId,
    String? abacaType,
    DateTime? orderDate,
    double? quantityKg,
    double? pricePerKg,
    double? totalAmount,
    OrderStatus? status,
    String? notes,
    bool clearNotes = false,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) =>
      Order(
        id: id ?? this.id,
        customerId: customerId ?? this.customerId,
        employeeId: employeeId ?? this.employeeId,
        inventoryId: inventoryId ?? this.inventoryId,
        abacaType: abacaType ?? this.abacaType,
        orderDate: orderDate ?? this.orderDate,
        quantityKg: quantityKg ?? this.quantityKg,
        pricePerKg: pricePerKg ?? this.pricePerKg,
        totalAmount: totalAmount ?? this.totalAmount,
        status: status ?? this.status,
        notes: clearNotes ? null : (notes ?? this.notes),
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Order &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          customerId == other.customerId &&
          employeeId == other.employeeId &&
          inventoryId == other.inventoryId &&
          abacaType == other.abacaType &&
          orderDate == other.orderDate &&
          DecimalPrecision.equals2(quantityKg, other.quantityKg) &&
          DecimalPrecision.equals2(pricePerKg, other.pricePerKg) &&
          DecimalPrecision.equals2(totalAmount, other.totalAmount) &&
          status == other.status &&
          notes == other.notes &&
          createdAt == other.createdAt &&
          updatedAt == other.updatedAt;

  @override
  int get hashCode => Object.hash(
        runtimeType,
        id,
        customerId,
        employeeId,
        inventoryId,
        abacaType,
        orderDate,
        DecimalPrecision.toMinorUnits(quantityKg),
        DecimalPrecision.toMinorUnits(pricePerKg),
        DecimalPrecision.toMinorUnits(totalAmount),
        status,
        notes,
        createdAt,
        updatedAt,
      );

  @override
  String toString() =>
      'Order(id: $id, customerId: $customerId, abacaType: $abacaType, quantityKg: $quantityKg, totalAmount: $totalAmount, status: ${status.dbValue})';
}

/// Composite read model bundling an [Order] with its customer/employee labels,
/// optional 1:1 [Delivery], and child [payments].
@immutable
final class OrderWithDetails {
  OrderWithDetails({
    required this.order,
    this.customerName,
    this.employeeName,
    this.delivery,
    List<Payment> payments = const <Payment>[],
  }) : payments = List<Payment>.unmodifiable(payments);

  final Order order;
  final String? customerName;
  final String? employeeName;
  final Delivery? delivery;
  final List<Payment> payments;

  /// Sum of all recorded payments against this order.
  double get totalPaid =>
      DecimalPrecision.sum2(payments.map((payment) => payment.amountPaid));

  /// Remaining unpaid balance clamped to `>= 0.0`.
  double get remainingBalance {
    final remaining = DecimalPrecision.subtract2(order.totalAmount, totalPaid);
    return DecimalPrecision.compare2(remaining, 0) < 0 ? 0.0 : remaining;
  }

  /// Payment progress derived from [totalPaid] vs [Order.totalAmount].
  OrderPaymentStatus get paymentStatus {
    if (DecimalPrecision.compare2(totalPaid, 0) <= 0) {
      return OrderPaymentStatus.unpaid;
    }
    if (DecimalPrecision.compare2(totalPaid, order.totalAmount) >= 0) {
      return OrderPaymentStatus.paid;
    }
    return OrderPaymentStatus.partiallyPaid;
  }

  static const ListEquality<Payment> _listEquality = ListEquality<Payment>();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OrderWithDetails &&
          runtimeType == other.runtimeType &&
          order == other.order &&
          customerName == other.customerName &&
          employeeName == other.employeeName &&
          delivery == other.delivery &&
          _listEquality.equals(payments, other.payments);

  @override
  int get hashCode => Object.hash(
        runtimeType,
        order,
        customerName,
        employeeName,
        delivery,
        _listEquality.hash(payments),
      );
}
