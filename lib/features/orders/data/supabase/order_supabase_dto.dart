import '../../../../core/data/supabase/supabase_helpers.dart';
import '../../../../core/utils/decimal_precision.dart';
import '../../../finance/data/supabase/payment_supabase_dto.dart';
import '../../domain/entities/delivery.dart';
import '../../domain/entities/order.dart';
import '../../domain/entities/order_status.dart';
import 'delivery_supabase_dto.dart';

/// Supabase DTO mapper for `orders` and hydrated [OrderWithDetails].
abstract final class OrderSupabaseDto {
  static const String tableName = 'orders';

  static const String joinedSelect =
      '*, customers(first_name, middle_name, last_name), '
      'employees(first_name, middle_name, last_name), '
      'deliveries(*), payments(*)';

  static Order fromSupabase(Map<String, dynamic> row) => Order(
        id: row['order_id'] as String,
        customerId: row['customer_id'] as String,
        employeeId: row['employee_id'] as String,
        inventoryId: row['inventory_id'] as String,
        abacaType: row['abaca_type'] as String,
        orderDate: SupabaseHelpers.parseDateOnly(row['order_date']),
        quantityKg: SupabaseHelpers.parseDouble(row['quantity_kg']),
        pricePerKg: SupabaseHelpers.parseDouble(row['price_per_kg']),
        totalAmount: SupabaseHelpers.parseDouble(row['total_amount']),
        status: OrderStatus.fromDb(row['status'] as String),
        notes: row['notes'] as String?,
        createdAt: SupabaseHelpers.parseTimestamp(row['created_at']),
        updatedAt: SupabaseHelpers.parseTimestamp(row['updated_at']),
      );

  static OrderWithDetails detailsFromSupabase(Map<String, dynamic> row) {
    final order = fromSupabase(row);
    final customerRow = row['customers'] as Map<String, dynamic>?;
    final employeeRow = row['employees'] as Map<String, dynamic>?;

    // PostgREST may return a 1:1 relation as a single Map or a 1-element List.
    Delivery? delivery;
    final rawDelivery = row['deliveries'];
    if (rawDelivery is Map<String, dynamic>) {
      delivery = DeliverySupabaseDto.fromSupabase(rawDelivery);
    } else if (rawDelivery is List &&
        rawDelivery.isNotEmpty &&
        rawDelivery.first is Map<String, dynamic>) {
      delivery = DeliverySupabaseDto.fromSupabase(
        rawDelivery.first as Map<String, dynamic>,
      );
    }

    final rawPayments = row['payments'] as List<dynamic>? ?? const <dynamic>[];
    final payments = rawPayments
        .whereType<Map<String, dynamic>>()
        .map(PaymentSupabaseDto.fromSupabase)
        .toList(growable: false);

    return OrderWithDetails(
      order: order,
      customerName: SupabaseHelpers.formatPersonName(customerRow),
      employeeName: SupabaseHelpers.formatPersonName(employeeRow),
      delivery: delivery,
      payments: payments,
    );
  }

  static Map<String, dynamic> toInsertMap({
    required String customerId,
    required String employeeId,
    required String inventoryId,
    required String abacaType,
    required DateTime orderDate,
    required double quantityKg,
    required double pricePerKg,
    required double totalAmount,
    String? notes,
  }) =>
      <String, dynamic>{
        'customer_id': customerId,
        'employee_id': employeeId,
        'inventory_id': inventoryId,
        'abaca_type': abacaType,
        'order_date': SupabaseHelpers.formatDateOnly(orderDate),
        'quantity_kg': DecimalPrecision.round2(quantityKg),
        'price_per_kg': DecimalPrecision.round2(pricePerKg),
        'total_amount': DecimalPrecision.round2(totalAmount),
        'status': OrderStatus.pending.dbValue,
        'notes': _trimOrNull(notes),
      };

  static String? _trimOrNull(String? value) {
    final trimmed = value?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }
}
