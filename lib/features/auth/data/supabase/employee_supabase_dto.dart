import '../../../../core/data/supabase/supabase_helpers.dart';
import '../../domain/entities/employee.dart';
import '../../domain/entities/employee_role.dart';

/// Supabase DTO mapper for the `employees` table.
///
/// Auth credentials are never stored here; `employee_id` equals `auth.users.id`.
abstract final class EmployeeSupabaseDto {
  static const String tableName = 'employees';

  static Employee fromSupabase(Map<String, dynamic> row) => Employee(
        id: row['employee_id'] as String,
        firstName: row['first_name'] as String,
        middleName: row['middle_name'] as String?,
        lastName: row['last_name'] as String,
        email: row['email'] as String,
        role: EmployeeRole.fromDb(row['role'] as String),
        isActive: (row['is_active'] as bool?) ?? true,
        createdAt: SupabaseHelpers.parseTimestamp(row['created_at']),
        updatedAt: SupabaseHelpers.parseTimestamp(row['updated_at']),
      );

  static Map<String, dynamic> toInsertMap({
    required String employeeId,
    required String firstName,
    String? middleName,
    required String lastName,
    required String email,
    required EmployeeRole role,
    bool isActive = true,
  }) =>
      <String, dynamic>{
        'employee_id': employeeId,
        'first_name': firstName.trim(),
        'middle_name': _trimOrNull(middleName),
        'last_name': lastName.trim(),
        'email': email.trim().toLowerCase(),
        'role': role.dbValue,
        'is_active': isActive,
      };

  static Map<String, dynamic> toUpdateMap(Employee employee) => <String, dynamic>{
        'first_name': employee.firstName.trim(),
        'middle_name': _trimOrNull(employee.middleName),
        'last_name': employee.lastName.trim(),
        'email': employee.email.trim().toLowerCase(),
        'role': employee.role.dbValue,
        'is_active': employee.isActive,
      };

  static String? _trimOrNull(String? value) {
    final trimmed = value?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }
}
