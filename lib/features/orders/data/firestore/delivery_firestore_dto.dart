import 'package:cloud_firestore/cloud_firestore.dart' hide Order, ListEquality;

import '../../../../core/data/firestore/firestore_helpers.dart';
import '../../domain/entities/delivery.dart';
import '../../domain/entities/delivery_status.dart';

/// Cloud Firestore DTO mapper for root `deliveries/{deliveryId}` docs.
abstract final class DeliveryFirestoreDto {
  static Delivery fromFirestore(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data()!;
    return Delivery(
      id: doc.id,
      orderId: data['order_id'] as String,
      employeeId: data['employee_id'] as String,
      deliveryDate: FirestoreHelpers.fromDateOnlyTimestamp(data['delivery_date']),
      deliveredAt: FirestoreHelpers.fromNullableTimestamp(data['delivered_at']),
      status: DeliveryStatus.fromDb(data['status'] as String),
      notes: data['notes'] as String?,
      createdAt: FirestoreHelpers.fromTimestamp(data['created_at']),
      updatedAt: FirestoreHelpers.fromTimestamp(data['updated_at']),
    );
  }

  static Map<String, dynamic> toFirestore({
    required String orderId,
    required String employeeId,
    required String employeeName,
    required DateTime deliveryDate,
    DateTime? deliveredAt,
    required DeliveryStatus status,
    String? notes,
    required DateTime createdAt,
    required DateTime updatedAt,
  }) {
    final trimmedNotes = notes?.trim();
    return <String, dynamic>{
      'order_id': orderId,
      'employee_id': employeeId,
      'employee_name': employeeName,
      'delivery_date': FirestoreHelpers.toDateOnlyTimestamp(deliveryDate),
      'delivered_at':
          deliveredAt == null ? null : FirestoreHelpers.toTimestamp(deliveredAt),
      'status': status.dbValue,
      'notes': (trimmedNotes == null || trimmedNotes.isEmpty) ? null : trimmedNotes,
      'created_at': FirestoreHelpers.toTimestamp(createdAt),
      'updated_at': FirestoreHelpers.toTimestamp(updatedAt),
    };
  }
}
