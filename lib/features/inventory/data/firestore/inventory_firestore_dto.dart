import 'package:cloud_firestore/cloud_firestore.dart' hide Order, ListEquality;

import '../../../../core/data/firestore/firestore_helpers.dart';
import '../../../../core/utils/decimal_precision.dart';
import '../../domain/entities/inventory.dart';

/// Cloud Firestore DTO mapper for `inventory/{inventoryId}`.
abstract final class InventoryFirestoreDto {
  static Inventory fromFirestore(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data()!;
    return Inventory(
      id: doc.id,
      abacaType: data['abaca_type'] as String,
      description: data['description'] as String?,
      currentStockKg: FirestoreHelpers.parseDouble(data['current_stock_kg']),
      minStockThresholdKg:
          FirestoreHelpers.parseDouble(data['min_stock_threshold_kg']),
      isActive: (data['is_active'] as bool?) ?? true,
      createdAt: FirestoreHelpers.fromTimestamp(data['created_at']),
      lastUpdated: FirestoreHelpers.fromTimestamp(data['last_updated']),
    );
  }

  static Map<String, dynamic> toFirestore({
    required String abacaType,
    String? description,
    required double currentStockKg,
    required double minStockThresholdKg,
    required bool isActive,
    required DateTime createdAt,
    required DateTime lastUpdated,
  }) {
    final trimmedDesc = description?.trim();
    return <String, dynamic>{
      'abaca_type': abacaType.trim(),
      'abaca_type_lower': abacaType.trim().toLowerCase(),
      'description':
          (trimmedDesc == null || trimmedDesc.isEmpty) ? null : trimmedDesc,
      'current_stock_kg': DecimalPrecision.round2(currentStockKg),
      'min_stock_threshold_kg': DecimalPrecision.round2(minStockThresholdKg),
      'is_active': isActive,
      'created_at': FirestoreHelpers.toTimestamp(createdAt),
      'last_updated': FirestoreHelpers.toTimestamp(lastUpdated),
    };
  }
}
