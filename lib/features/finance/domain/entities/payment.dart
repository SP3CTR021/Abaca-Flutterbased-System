import 'package:meta/meta.dart';

import '../../../../core/utils/decimal_precision.dart';

/// Customer payment recorded against a `stocked` or `delivered` order (`payments`).
///
/// Relationships:
/// - `N:1` child of `orders` (`payments.order_id`, `ON DELETE RESTRICT` when
///   payments exist; void payments first before deleting an order).
/// - `N:1` child of `employees` (`payments.employee_id`, `ON DELETE RESTRICT` —
///   added so every financial entry records the responsible staff member).
///
/// Firestore note: Stored in subcollection `orders/{orderId}/payments/{paymentId}`
/// (with `order_id` mirrored in the document for `collectionGroup('payments')`
/// reporting) and syncs `paid_amount` onto `orders/{orderId}` inside `runTransaction`.
@immutable
final class Payment {
  const Payment({
    required this.id,
    required this.orderId,
    required this.employeeId,
    required this.amountPaid,
    required this.paymentDate,
    required this.paymentMethod,
    this.referenceNumber,
    this.notes,
    required this.createdAt,
    required this.updatedAt,
  });

  /// Primary key (`payment_id`).
  final String id;
  final String orderId;

  /// Staff member who recorded this payment (`payments.employee_id`).
  final String employeeId;
  final double amountPaid;
  final DateTime paymentDate;
  final String paymentMethod;

  /// Optional external bank/GCash/receipt reference number.
  final String? referenceNumber;
  final String? notes;
  final DateTime createdAt;
  final DateTime updatedAt;

  Payment copyWith({
    String? id,
    String? orderId,
    String? employeeId,
    double? amountPaid,
    DateTime? paymentDate,
    String? paymentMethod,
    String? referenceNumber,
    bool clearReferenceNumber = false,
    String? notes,
    bool clearNotes = false,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) =>
      Payment(
        id: id ?? this.id,
        orderId: orderId ?? this.orderId,
        employeeId: employeeId ?? this.employeeId,
        amountPaid: amountPaid ?? this.amountPaid,
        paymentDate: paymentDate ?? this.paymentDate,
        paymentMethod: paymentMethod ?? this.paymentMethod,
        referenceNumber: clearReferenceNumber
            ? null
            : (referenceNumber ?? this.referenceNumber),
        notes: clearNotes ? null : (notes ?? this.notes),
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Payment &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          orderId == other.orderId &&
          employeeId == other.employeeId &&
          DecimalPrecision.equals2(amountPaid, other.amountPaid) &&
          paymentDate == other.paymentDate &&
          paymentMethod == other.paymentMethod &&
          referenceNumber == other.referenceNumber &&
          notes == other.notes &&
          createdAt == other.createdAt &&
          updatedAt == other.updatedAt;

  @override
  int get hashCode => Object.hash(
        runtimeType,
        id,
        orderId,
        employeeId,
        DecimalPrecision.toMinorUnits(amountPaid),
        paymentDate,
        paymentMethod,
        referenceNumber,
        notes,
        createdAt,
        updatedAt,
      );

  @override
  String toString() =>
      'Payment(id: $id, orderId: $orderId, amountPaid: $amountPaid, paymentMethod: $paymentMethod)';
}
