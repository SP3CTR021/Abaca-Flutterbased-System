import 'package:cloud_firestore/cloud_firestore.dart' hide Order, ListEquality;

import '../../../../core/data/firestore/firestore_helpers.dart';
import '../../../../core/utils/decimal_precision.dart';
import '../../domain/entities/stock_in.dart';
import '../../domain/entities/stock_in_item.dart';

/// Cloud Firestore DTO mapper for `stock_ins/{stockinId}` and subcollection
/// `stock_ins/{stockinId}/items/{itemId}`.
abstract final class StockInFirestoreDto {
  static StockIn fromFirestore(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data()!;
    return StockIn(
      id: doc.id,
      orderId: data['order_id'] as String?,
      supplierId: data['supplier_id'] as String,
      employeeId: data['employee_id'] as String,
      dateReceived: FirestoreHelpers.fromDateOnlyTimestamp(data['date_received']),
      notes: data['notes'] as String?,
      createdAt: FirestoreHelpers.fromTimestamp(data['created_at']),
      updatedAt: FirestoreHelpers.fromTimestamp(data['updated_at']),
    );
  }

  static StockInItem itemFromFirestore(
    DocumentSnapshot<Map<String, dynamic>> doc, {
    required String stockInId,
  }) {
    final data = doc.data()!;
    return StockInItem(
      id: doc.id,
      stockInId: (data['stockin_id'] as String?) ?? stockInId,
      inventoryId: data['inventory_id'] as String,
      quantityKg: FirestoreHelpers.parseDouble(data['quantity_kg']),
      costPerKg: FirestoreHelpers.parseDouble(data['cost_per_kg']),
      createdAt: FirestoreHelpers.fromTimestamp(data['created_at']),
      updatedAt: FirestoreHelpers.fromTimestamp(data['updated_at']),
    );
  }

  static StockInWithDetails detailsFromFirestore({
    required DocumentSnapshot<Map<String, dynamic>> headerDoc,
    required List<DocumentSnapshot<Map<String, dynamic>>> itemDocs,
  }) {
    final stockIn = fromFirestore(headerDoc);
    final data = headerDoc.data()!;
    final rawMap = data['abaca_type_by_inventory_id'];
    final abacaMap = <String, String>{};
    if (rawMap is Map) {
      for (final entry in rawMap.entries) {
        if (entry.key is String && entry.value is String) {
          abacaMap[entry.key as String] = entry.value as String;
        }
      }
    }

    final items = itemDocs
        .map((doc) {
          final item = itemFromFirestore(doc, stockInId: stockIn.id);
          final itemType = doc.data()?['abaca_type'] as String?;
          if (itemType != null) {
            abacaMap.putIfAbsent(item.inventoryId, () => itemType);
          }
          return item;
        })
        .toList(growable: false);

    return StockInWithDetails(
      stockIn: stockIn,
      items: items,
      supplierName: data['supplier_name'] as String?,
      employeeName: data['employee_name'] as String?,
      abacaTypeByInventoryId: abacaMap,
    );
  }

  static Map<String, dynamic> headerToFirestore({
    String? orderId,
    required String supplierId,
    required String employeeId,
    required DateTime dateReceived,
    String? notes,
    required String supplierName,
    required String employeeName,
    required List<String> inventoryIds,
    required Map<String, String> abacaTypeByInventoryId,
    required double totalCost,
    required DateTime createdAt,
    required DateTime updatedAt,
  }) {
    final trimmedNotes = notes?.trim();
    return <String, dynamic>{
      'order_id': orderId,
      'supplier_id': supplierId,
      'employee_id': employeeId,
      'date_received': FirestoreHelpers.toDateOnlyTimestamp(dateReceived),
      'notes': (trimmedNotes == null || trimmedNotes.isEmpty) ? null : trimmedNotes,
      'supplier_name': supplierName,
      'employee_name': employeeName,
      'inventory_ids': inventoryIds,
      'abaca_type_by_inventory_id': abacaTypeByInventoryId,
      'total_cost': DecimalPrecision.round2(totalCost),
      'created_at': FirestoreHelpers.toTimestamp(createdAt),
      'updated_at': FirestoreHelpers.toTimestamp(updatedAt),
    };
  }

  static Map<String, dynamic> itemToFirestore({
    required String stockInId,
    required String inventoryId,
    required String abacaType,
    required double quantityKg,
    required double costPerKg,
    required DateTime dateReceived,
    required DateTime createdAt,
    required DateTime updatedAt,
  }) {
    final qty = DecimalPrecision.round2(quantityKg);
    final cost = DecimalPrecision.round2(costPerKg);
    return <String, dynamic>{
      'stockin_id': stockInId,
      'inventory_id': inventoryId,
      'abaca_type': abacaType,
      'quantity_kg': qty,
      'cost_per_kg': cost,
      // Precomputed line total enables Firestore AggregateQuery sum('total_cost').
      'total_cost': DecimalPrecision.multiply2(qty, cost),
      'date_received': FirestoreHelpers.toDateOnlyTimestamp(dateReceived),
      'created_at': FirestoreHelpers.toTimestamp(createdAt),
      'updated_at': FirestoreHelpers.toTimestamp(updatedAt),
    };
  }
}
