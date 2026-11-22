import 'package:cloud_firestore/cloud_firestore.dart' hide Order, ListEquality;

import '../../../../core/data/firestore/firestore_helpers.dart';
import '../../../../core/utils/decimal_precision.dart';
import '../../../finance/domain/entities/payment.dart';
import '../../domain/entities/delivery.dart';
import '../../domain/entities/order.dart';
import '../../domain/entities/order_status.dart';

/// Cloud Firestore DTO mapper for `orders/{orderId}` documents.
///
/// Denormalized fields (`customer_name`, `employee_name`, `paid_amount`,
/// `delivery_id`, `delivery_status`) live exclusively inside this Firestore DTO
/// so list views avoid N+1 reads while the pure [Order] domain entity stays clean.
abstract final class OrderFirestoreDto {
  static Order fromFirestore(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data()!;
    return Order(
      id: doc.id,
      customerId: data['customer_id'] as String,
      employeeId: data['employee_id'] as String,
      inventoryId: data['inventory_id'] as String,
      abacaType: data['abaca_type'] as String,
      orderDate: FirestoreHelpers.fromDateOnlyTimestamp(data['order_date']),
      quantityKg: FirestoreHelpers.parseDouble(data['quantity_kg']),
      pricePerKg: FirestoreHelpers.parseDouble(data['price_per_kg']),
      totalAmount: FirestoreHelpers.parseDouble(data['total_amount']),
      status: OrderStatus.fromDb(data['status'] as String),
      notes: data['notes'] as String?,
      createdAt: FirestoreHelpers.fromTimestamp(data['created_at']),
      updatedAt: FirestoreHelpers.fromTimestamp(data['updated_at']),
    );
  }

  static OrderWithDetails detailsFromFirestore({
    required DocumentSnapshot<Map<String, dynamic>> orderDoc,
    Delivery? delivery,
    required List<Payment> payments,
  }) {
    final data = orderDoc.data()!;
    return OrderWithDetails(
      order: fromFirestore(orderDoc),
      customerName: data['customer_name'] as String?,
      employeeName: data['employee_name'] as String?,
      delivery: delivery,
      payments: payments,
    );
  }

  static Map<String, dynamic> toFirestore({
    required String customerId,
    required String customerName,
    required String employeeId,
    required String employeeName,
    required String inventoryId,
    required String abacaType,
    required DateTime orderDate,
    required double quantityKg,
    required double pricePerKg,
    required double totalAmount,
    required OrderStatus status,
    required double paidAmount,
    String? deliveryId,
    String? deliveryStatus,
    String? notes,
    required DateTime createdAt,
    required DateTime updatedAt,
  }) {
    final trimmedNotes = notes?.trim();
    return <String, dynamic>{
      'customer_id': customerId,
      'customer_name': customerName,
      'employee_id': employeeId,
      'employee_name': employeeName,
      'inventory_id': inventoryId,
      'abaca_type': abacaType,
      'order_date': FirestoreHelpers.toDateOnlyTimestamp(orderDate),
      'quantity_kg': DecimalPrecision.round2(quantityKg),
      'price_per_kg': DecimalPrecision.round2(pricePerKg),
      'total_amount': DecimalPrecision.round2(totalAmount),
      'paid_amount': DecimalPrecision.round2(paidAmount),
      'delivery_id': deliveryId,
      'delivery_status': deliveryStatus,
      'status': status.dbValue,
      'notes': (trimmedNotes == null || trimmedNotes.isEmpty) ? null : trimmedNotes,
      'created_at': FirestoreHelpers.toTimestamp(createdAt),
      'updated_at': FirestoreHelpers.toTimestamp(updatedAt),
    };
  }
}
