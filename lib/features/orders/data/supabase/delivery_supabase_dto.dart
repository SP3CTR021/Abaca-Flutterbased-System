import '../../../../core/data/supabase/supabase_helpers.dart';
import '../../domain/entities/delivery.dart';
import '../../domain/entities/delivery_status.dart';

/// Supabase DTO mapper for the `deliveries` table.
abstract final class DeliverySupabaseDto {
  static const String tableName = 'deliveries';

  static Delivery fromSupabase(Map<String, dynamic> row) => Delivery(
        id: row['delivery_id'] as String,
        orderId: row['order_id'] as String,
        employeeId: row['employee_id'] as String,
        deliveryDate: SupabaseHelpers.parseDateOnly(row['delivery_date']),
        deliveredAt: SupabaseHelpers.parseNullableTimestamp(row['delivered_at']),
        status: DeliveryStatus.fromDb(row['status'] as String),
        notes: row['notes'] as String?,
        createdAt: SupabaseHelpers.parseTimestamp(row['created_at']),
        updatedAt: SupabaseHelpers.parseTimestamp(row['updated_at']),
      );

  static Map<String, dynamic> toInsertMap({
    required String orderId,
    required String employeeId,
    required DateTime deliveryDate,
    String? notes,
  }) =>
      <String, dynamic>{
        'order_id': orderId,
        'employee_id': employeeId,
        'delivery_date': SupabaseHelpers.formatDateOnly(deliveryDate),
        'status': DeliveryStatus.pending.dbValue,
        'notes': _trimOrNull(notes),
      };

  static String? _trimOrNull(String? value) {
    final trimmed = value?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }
}
