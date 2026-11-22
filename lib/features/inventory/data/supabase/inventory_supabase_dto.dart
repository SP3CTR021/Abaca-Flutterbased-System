import '../../../../core/data/supabase/supabase_helpers.dart';
import '../../../../core/utils/decimal_precision.dart';
import '../../domain/entities/inventory.dart';

/// Supabase DTO mapper for the `inventory` master stock ledger.
abstract final class InventorySupabaseDto {
  static const String tableName = 'inventory';

  static Inventory fromSupabase(Map<String, dynamic> row) => Inventory(
        id: row['inventory_id'] as String,
        abacaType: row['abaca_type'] as String,
        description: row['description'] as String?,
        currentStockKg: SupabaseHelpers.parseDouble(row['current_stock_kg']),
        minStockThresholdKg:
            SupabaseHelpers.parseDouble(row['min_stock_threshold_kg']),
        isActive: (row['is_active'] as bool?) ?? true,
        createdAt: SupabaseHelpers.parseTimestamp(row['created_at']),
        lastUpdated: SupabaseHelpers.parseTimestamp(row['last_updated']),
      );

  static Map<String, dynamic> toInsertMap({
    required String abacaType,
    String? description,
    double initialStockKg = 0.0,
    double minStockThresholdKg = 0.0,
  }) =>
      <String, dynamic>{
        'abaca_type': abacaType.trim(),
        'description': _trimOrNull(description),
        'current_stock_kg': DecimalPrecision.round2(initialStockKg),
        'min_stock_threshold_kg': DecimalPrecision.round2(minStockThresholdKg),
      };

  static String? _trimOrNull(String? value) {
    final trimmed = value?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }
}
