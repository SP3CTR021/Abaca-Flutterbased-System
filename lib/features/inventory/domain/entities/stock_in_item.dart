import 'package:meta/meta.dart';

import '../../../../core/utils/decimal_precision.dart';

/// Line item belonging to a `stock_ins` receipt header (`stock_in_items`).
///
/// Serves as the attributed `M:N` join between `stock_ins` and `inventory`:
/// - `N:1` child of `stock_ins` (`stock_in_items.stockin_id`, `ON DELETE CASCADE`).
/// - `N:1` child of `inventory` (`stock_in_items.inventory_id`, `ON DELETE RESTRICT`).
///
/// Firestore note: Stored in subcollection `stock_ins/{stockinId}/items/{id}`
/// with denormalized `total_cost` so server-side `.sum('total_cost')` and
/// `collectionGroup('items')` inventory queries work without N+1 reads.
@immutable
final class StockInItem {
  const StockInItem({
    required this.id,
    required this.stockInId,
    required this.inventoryId,
    required this.quantityKg,
    required this.costPerKg,
    required this.createdAt,
    required this.updatedAt,
  });

  /// Primary key (`stock_in_item_id`).
  final String id;

  /// Parent receipt FK (`stock_in_items.stockin_id`).
  final String stockInId;

  /// Target abaca grade FK (`stock_in_items.inventory_id`).
  final String inventoryId;
  final double quantityKg;
  final double costPerKg;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Line-item purchase cost (`quantityKg * costPerKg` rounded to 2 decimals).
  double get totalCost => DecimalPrecision.multiply2(quantityKg, costPerKg);

  StockInItem copyWith({
    String? id,
    String? stockInId,
    String? inventoryId,
    double? quantityKg,
    double? costPerKg,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) =>
      StockInItem(
        id: id ?? this.id,
        stockInId: stockInId ?? this.stockInId,
        inventoryId: inventoryId ?? this.inventoryId,
        quantityKg: quantityKg ?? this.quantityKg,
        costPerKg: costPerKg ?? this.costPerKg,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StockInItem &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          stockInId == other.stockInId &&
          inventoryId == other.inventoryId &&
          DecimalPrecision.equals2(quantityKg, other.quantityKg) &&
          DecimalPrecision.equals2(costPerKg, other.costPerKg) &&
          createdAt == other.createdAt &&
          updatedAt == other.updatedAt;

  @override
  int get hashCode => Object.hash(
        runtimeType,
        id,
        stockInId,
        inventoryId,
        DecimalPrecision.toMinorUnits(quantityKg),
        DecimalPrecision.toMinorUnits(costPerKg),
        createdAt,
        updatedAt,
      );

  @override
  String toString() =>
      'StockInItem(id: $id, stockInId: $stockInId, inventoryId: $inventoryId, quantityKg: $quantityKg, costPerKg: $costPerKg)';
}

/// Input value object used when creating a new [StockIn] receipt.
@immutable
final class NewStockInItemInput {
  const NewStockInItemInput({
    required this.inventoryId,
    required this.quantityKg,
    required this.costPerKg,
  });

  final String inventoryId;
  final double quantityKg;
  final double costPerKg;

  /// Expected line-item purchase cost (`quantityKg * costPerKg`).
  double get totalCost => DecimalPrecision.multiply2(quantityKg, costPerKg);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NewStockInItemInput &&
          runtimeType == other.runtimeType &&
          inventoryId == other.inventoryId &&
          DecimalPrecision.equals2(quantityKg, other.quantityKg) &&
          DecimalPrecision.equals2(costPerKg, other.costPerKg);

  @override
  int get hashCode => Object.hash(
        runtimeType,
        inventoryId,
        DecimalPrecision.toMinorUnits(quantityKg),
        DecimalPrecision.toMinorUnits(costPerKg),
      );
}
