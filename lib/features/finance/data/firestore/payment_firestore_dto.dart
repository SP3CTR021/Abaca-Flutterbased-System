import 'package:cloud_firestore/cloud_firestore.dart' hide Order, ListEquality;

import '../../../../core/data/firestore/firestore_helpers.dart';
import '../../../../core/utils/decimal_precision.dart';
import '../../domain/entities/payment.dart';

/// Cloud Firestore DTO mapper for subcollection `orders/{orderId}/payments/{paymentId}`.
abstract final class PaymentFirestoreDto {
  static Payment fromFirestore(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data()!;
    return Payment(
      id: doc.id,
      orderId: data['order_id'] as String,
      employeeId: data['employee_id'] as String,
      amountPaid: FirestoreHelpers.parseDouble(data['amount_paid']),
      paymentDate: FirestoreHelpers.fromDateOnlyTimestamp(data['payment_date']),
      paymentMethod: data['payment_method'] as String,
      referenceNumber: data['reference_number'] as String?,
      notes: data['notes'] as String?,
      createdAt: FirestoreHelpers.fromTimestamp(data['created_at']),
      updatedAt: FirestoreHelpers.fromTimestamp(data['updated_at']),
    );
  }

  static Map<String, dynamic> toFirestore({
    required String paymentId,
    required String orderId,
    required String employeeId,
    required double amountPaid,
    required DateTime paymentDate,
    required String paymentMethod,
    String? referenceNumber,
    String? notes,
    required DateTime createdAt,
    required DateTime updatedAt,
  }) {
    final trimmedRef = referenceNumber?.trim();
    final trimmedNotes = notes?.trim();
    return <String, dynamic>{
      'payment_id': paymentId,
      'order_id': orderId,
      'employee_id': employeeId,
      'amount_paid': DecimalPrecision.round2(amountPaid),
      'payment_date': FirestoreHelpers.toDateOnlyTimestamp(paymentDate),
      'payment_method': paymentMethod.trim(),
      'reference_number':
          (trimmedRef == null || trimmedRef.isEmpty) ? null : trimmedRef,
      'notes': (trimmedNotes == null || trimmedNotes.isEmpty) ? null : trimmedNotes,
      'created_at': FirestoreHelpers.toTimestamp(createdAt),
      'updated_at': FirestoreHelpers.toTimestamp(updatedAt),
    };
  }
}
