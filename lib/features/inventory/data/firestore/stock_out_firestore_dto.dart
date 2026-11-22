import 'package:cloud_firestore/cloud_firestore.dart' hide Order, ListEquality;

import '../../../../core/data/firestore/firestore_helpers.dart';
import '../../../../core/utils/decimal_precision.dart';
import '../../domain/entities/stock_out.dart';
import '../../domain/entities/stock_out_reason.dart';

/// Cloud Firestore DTO mapper for `stock_outs/{stockoutId}`.
abstract final class StockOutFirestoreDto {
  static StockOut fromFirestore(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data()!;
    return StockOut(
      id: doc.id,
      inventoryId: data['inventory_id'] as String,
      employeeId: data['employee_id'] as String,
      deliveryId: data['delivery_id'] as String?,
      orderId: data['order_id'] as String?,
      quantityKg: FirestoreHelpers.parseDouble(data['quantity_kg']),
      reason: StockOutReason.fromDb(data['reason'] as String),
      notes: data['notes'] as String?,
      date: FirestoreHelpers.fromDateOnlyTimestamp(data['date']),
      createdAt: FirestoreHelpers.fromTimestamp(data['created_at']),
      updatedAt: FirestoreHelpers.fromTimestamp(data['updated_at']),
    );
  }

  static Map<String, dynamic> toFirestore({
    required String inventoryId,
    required String abacaType,
    required String employeeId,
    required String employeeName,
    String? deliveryId,
    String? orderId,
    required double quantityKg,
    required StockOutReason reason,
    String? notes,
    required DateTime date,
    required DateTime createdAt,
    required DateTime updatedAt,
  }) {
    final trimmedNotes = notes?.trim();
    return <String, dynamic>{
      'inventory_id': inventoryId,
      'abaca_type': abacaType,
      'employee_id': employeeId,
      'employee_name': employeeName,
      'delivery_id': deliveryId,
      'order_id': orderId,
      'quantity_kg': DecimalPrecision.round2(quantityKg),
      'reason': reason.dbValue,
      'notes': (trimmedNotes == null || trimmedNotes.isEmpty) ? null : trimmedNotes,
      'date': FirestoreHelpers.toDateOnlyTimestamp(date),
      'created_at': FirestoreHelpers.toTimestamp(createdAt),
      'updated_at': FirestoreHelpers.toTimestamp(updatedAt),
    };
  }
}
