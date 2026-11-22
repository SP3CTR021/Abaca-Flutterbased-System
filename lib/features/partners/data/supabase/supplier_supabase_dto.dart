import '../../../../core/data/supabase/supabase_helpers.dart';
import '../../domain/entities/supplier.dart';

/// Supabase DTO mapper for the `suppliers` table.
abstract final class SupplierSupabaseDto {
  static const String tableName = 'suppliers';

  static Supplier fromSupabase(Map<String, dynamic> row) => Supplier(
        id: row['supplier_id'] as String,
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

  static Map<String, dynamic> toUpdateMap(Supplier supplier) => <String, dynamic>{
        'first_name': supplier.firstName.trim(),
        'middle_name': _trimOrNull(supplier.middleName),
        'last_name': supplier.lastName.trim(),
        'contact_number': _trimOrNull(supplier.contactNumber),
        'address': _trimOrNull(supplier.address),
        'is_active': supplier.isActive,
      };

  static String? _trimOrNull(String? value) {
    final trimmed = value?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }
}
