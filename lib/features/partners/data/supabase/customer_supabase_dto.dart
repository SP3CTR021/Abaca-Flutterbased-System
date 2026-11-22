import '../../../../core/data/supabase/supabase_helpers.dart';
import '../../domain/entities/customer.dart';

/// Supabase DTO mapper for the `customers` table.
abstract final class CustomerSupabaseDto {
  static const String tableName = 'customers';

  static Customer fromSupabase(Map<String, dynamic> row) => Customer(
        id: row['customer_id'] as String,
        firstName: row['first_name'] as String,
        middleName: row['middle_name'] as String?,
        lastName: row['last_name'] as String,
        contactNumber: row['contact_number'] as String?,
        address: row['address'] as String?,
        isActive: (row['is_active'] as bool?) ?? true,
        createdAt: SupabaseHelpers.parseTimestamp(row['created_at']),
        updatedAt: SupabaseHelpers.parseTimestamp(row['updated_at']),
      );

  static Map<String, dynamic> toInsertMap({
    required String firstName,
    String? middleName,
    required String lastName,
    String? contactNumber,
    String? address,
  }) =>
      <String, dynamic>{
        'first_name': firstName.trim(),
        'middle_name': _trimOrNull(middleName),
        'last_name': lastName.trim(),
        'contact_number': _trimOrNull(contactNumber),
        'address': _trimOrNull(address),
      };

  static Map<String, dynamic> toUpdateMap(Customer customer) => <String, dynamic>{
        'first_name': customer.firstName.trim(),
        'middle_name': _trimOrNull(customer.middleName),
        'last_name': customer.lastName.trim(),
        'contact_number': _trimOrNull(customer.contactNumber),
        'address': _trimOrNull(customer.address),
        'is_active': customer.isActive,
      };

  static String? _trimOrNull(String? value) {
    final trimmed = value?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }
}
