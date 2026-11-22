import 'package:meta/meta.dart';

import '../../../../core/utils/decimal_precision.dart';

/// Master stock ledger per abaca fiber grade (`inventory` table / collection).
///
/// Relationships (`ON DELETE RESTRICT` + [isActive] archival):
/// - `1:N` parent of `stock_in_items` (`stock_in_items.inventory_id`).
/// - `1:N` parent of `stock_outs` (`stock_outs.inventory_id`).
/// - `1:N` parent of `orders` (`orders.inventory_id` FK — added to eliminate
///   unreferenced string matching on `orders.abaca_type`).
///
/// Concurrency & uniqueness note:
/// - Postgres enforces `UNIQUE(abaca_type)` and `ON UPDATE CASCADE` to `orders`.
/// - Firestore guarantees unique `abaca_type` via lock document
///   `inventory_type_locks/{normalizedType}` inside `runTransaction` and syncs
///   grade renames cleanly.
@immutable
final class Inventory {
  const Inventory({
    required this.id,
    required this.abacaType,
    this.description,
    required this.currentStockKg,
    this.minStockThresholdKg = 0.0,
    this.isActive = true,
    required this.createdAt,
    required this.lastUpdated,
  });

  /// Primary key (`inventory_id`).
  final String id;

  /// Unique abaca fiber grade code/label (e.g. `S2`, `S3`, `G`, `I`, `JK`).
  final String abacaType;
  final String? description;
  final double currentStockKg;

  /// Reorder alert threshold in kg (added to replace stub `StockThreshold`).
  final double minStockThresholdKg;
  final bool isActive;
  final DateTime createdAt;

  /// Timestamp of last stock or grade metadata change (`inventory.last_updated`).
  final DateTime lastUpdated;

  /// `true` when active stock has reached or fallen below [minStockThresholdKg].
  bool get isLowStock =>
      isActive && DecimalPrecision.compare2(currentStockKg, minStockThresholdKg) <= 0;

  /// `true` when available stock is zero (or negative).
  bool get isOutOfStock => DecimalPrecision.compare2(currentStockKg, 0) <= 0;

  Inventory copyWith({
    String? id,
    String? abacaType,
    String? description,
    bool clearDescription = false,
    double? currentStockKg,
    double? minStockThresholdKg,
    bool? isActive,
    DateTime? createdAt,
    DateTime? lastUpdated,
  }) =>
      Inventory(
        id: id ?? this.id,
        abacaType: abacaType ?? this.abacaType,
        description:
            clearDescription ? null : (description ?? this.description),
        currentStockKg: currentStockKg ?? this.currentStockKg,
        minStockThresholdKg: minStockThresholdKg ?? this.minStockThresholdKg,
        isActive: isActive ?? this.isActive,
        createdAt: createdAt ?? this.createdAt,
        lastUpdated: lastUpdated ?? this.lastUpdated,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Inventory &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          abacaType == other.abacaType &&
          description == other.description &&
          DecimalPrecision.equals2(currentStockKg, other.currentStockKg) &&
          DecimalPrecision.equals2(
            minStockThresholdKg,
            other.minStockThresholdKg,
          ) &&
          isActive == other.isActive &&
          createdAt == other.createdAt &&
          lastUpdated == other.lastUpdated;

  @override
  int get hashCode => Object.hash(
        runtimeType,
        id,
        abacaType,
        description,
        DecimalPrecision.toMinorUnits(currentStockKg),
        DecimalPrecision.toMinorUnits(minStockThresholdKg),
        isActive,
        createdAt,
        lastUpdated,
      );

  @override
  String toString() =>
      'Inventory(id: $id, abacaType: $abacaType, currentStockKg: $currentStockKg, minStockThresholdKg: $minStockThresholdKg, isActive: $isActive)';
}
