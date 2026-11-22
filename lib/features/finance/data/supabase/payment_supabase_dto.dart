import '../../../../core/data/supabase/supabase_helpers.dart';
import '../../domain/entities/payment.dart';

/// Supabase DTO mapper for the `payments` table.
abstract final class PaymentSupabaseDto {
  static const String tableName = 'payments';

  static Payment fromSupabase(Map<String, dynamic> row) => Payment(
        id: row['payment_id'] as String,
        orderId: row['order_id'] as String,
        employeeId: row['employee_id'] as String,
        amountPaid: SupabaseHelpers.parseDouble(row['amount_paid']),
        paymentDate: SupabaseHelpers.parseDateOnly(row['payment_date']),
        paymentMethod: row['payment_method'] as String,
        referenceNumber: row['reference_number'] as String?,
        notes: row['notes'] as String?,
        createdAt: SupabaseHelpers.parseTimestamp(row['created_at']),
        updatedAt: SupabaseHelpers.parseTimestamp(row['updated_at']),
      );
}
