import '../../../../core/data/supabase/supabase_helpers.dart';
import '../../domain/entities/stock_out.dart';
import '../../domain/entities/stock_out_reason.dart';

/// Supabase DTO mapper for the `stock_outs` table.
abstract final class StockOutSupabaseDto {
  static const String tableName = 'stock_outs';

  static StockOut fromSupabase(Map<String, dynamic> row) => StockOut(
        id: row['stockout_id'] as String,
        inventoryId: row['inventory_id'] as String,
        employeeId: row['employee_id'] as String,
        deliveryId: row['delivery_id'] as String?,
        orderId: row['order_id'] as String?,
        quantityKg: SupabaseHelpers.parseDouble(row['quantity_kg']),
        reason: StockOutReason.fromDb(row['reason'] as String),
        notes: row['notes'] as String?,
        date: SupabaseHelpers.parseDateOnly(row['date']),
        createdAt: SupabaseHelpers.parseTimestamp(row['created_at']),
        updatedAt: SupabaseHelpers.parseTimestamp(row['updated_at']),
      );
}
