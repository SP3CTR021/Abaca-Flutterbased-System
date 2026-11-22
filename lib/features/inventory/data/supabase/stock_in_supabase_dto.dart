import '../../../../core/data/supabase/supabase_helpers.dart';
import '../../../../core/utils/decimal_precision.dart';
import '../../domain/entities/stock_in.dart';
import '../../domain/entities/stock_in_item.dart';

/// Supabase DTO mapper for `stock_ins`, `stock_in_items`, and joined details.
abstract final class StockInSupabaseDto {
  static const String tableName = 'stock_ins';
  static const String itemsTableName = 'stock_in_items';

  static const String joinedSelect =
      '*, stock_in_items(*, inventory(abaca_type)), '
      'suppliers(first_name, middle_name, last_name), '
      'employees(first_name, middle_name, last_name)';

  static StockIn fromSupabase(Map<String, dynamic> row) => StockIn(
        id: row['stockin_id'] as String,
        orderId: row['order_id'] as String?,
        supplierId: row['supplier_id'] as String,
        employeeId: row['employee_id'] as String,
        dateReceived: SupabaseHelpers.parseDateOnly(row['date_received']),
        notes: row['notes'] as String?,
        createdAt: SupabaseHelpers.parseTimestamp(row['created_at']),
        updatedAt: SupabaseHelpers.parseTimestamp(row['updated_at']),
      );

  static StockInItem itemFromSupabase(Map<String, dynamic> row) => StockInItem(
        id: row['stock_in_item_id'] as String,
        stockInId: row['stockin_id'] as String,
        inventoryId: row['inventory_id'] as String,
        quantityKg: SupabaseHelpers.parseDouble(row['quantity_kg']),
        costPerKg: SupabaseHelpers.parseDouble(row['cost_per_kg']),
        createdAt: SupabaseHelpers.parseTimestamp(row['created_at']),
        updatedAt: SupabaseHelpers.parseTimestamp(row['updated_at']),
      );

  static StockInWithDetails detailsFromSupabase(Map<String, dynamic> row) {
    final stockIn = fromSupabase(row);
    final rawItems = row['stock_in_items'] as List<dynamic>? ?? const <dynamic>[];
    final items = <StockInItem>[];
    final abacaTypes = <String, String>{};

    for (final rawItem in rawItems) {
      if (rawItem is! Map<String, dynamic>) continue;
      final item = itemFromSupabase(rawItem);
      items.add(item);
      final inv = rawItem['inventory'];
      if (inv is Map<String, dynamic>) {
        final label = inv['abaca_type'] as String?;
        if (label != null) {
          abacaTypes[item.inventoryId] = label;
        }
      }
    }

    final supplierRow = row['suppliers'] as Map<String, dynamic>?;
    final employeeRow = row['employees'] as Map<String, dynamic>?;

    return StockInWithDetails(
      stockIn: stockIn,
      items: items,
      supplierName: SupabaseHelpers.formatPersonName(supplierRow),
      employeeName: SupabaseHelpers.formatPersonName(employeeRow),
      abacaTypeByInventoryId: abacaTypes,
    );
  }

  static List<Map<String, dynamic>> itemsToRpcJson(
    List<NewStockInItemInput> items,
  ) =>
      items
          .map(
            (item) => <String, dynamic>{
              'inventory_id': item.inventoryId,
              'quantity_kg': DecimalPrecision.round2(item.quantityKg),
              'cost_per_kg': DecimalPrecision.round2(item.costPerKg),
            },
          )
          .toList(growable: false);
}
