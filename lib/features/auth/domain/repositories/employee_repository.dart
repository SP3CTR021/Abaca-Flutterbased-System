import '../../../../core/result/result.dart';
import '../entities/employee.dart';
import '../entities/employee_role.dart';

/// Manages staff profiles (`employees` table / `employees` root collection).
abstract interface class EmployeeRepository {
  /// Fetches an [Employee] by [id] (`employee_id`), returning `NotFoundFailure`
  /// if missing.
  Future<Result<Employee>> getEmployeeById(String id);

  /// Looks up an [Employee] by unique [email], returning `null` if none exists.
  Future<Result<Employee?>> getEmployeeByEmail(String email);

  /// Lists employees optionally filtered by [role] and/or [isActive].
  Future<Result<List<Employee>>> getEmployees({
    EmployeeRole? role,
    bool? isActive,
  });

  /// Streams employees optionally filtered by [role] and/or [isActive].
  Stream<List<Employee>> watchEmployees({
    EmployeeRole? role,
    bool? isActive,
  });

  /// Updates an employee's profile details and logs an `updated` audit entry.
  ///
  /// In Firestore, name changes may trigger denormalized name sync across active
  /// records; Supabase resolves names via SQL joins.
  Future<Result<Employee>> updateEmployee(
    Employee employee, {
    String? actorEmployeeId,
  });

  /// Archives (`isActive: false`) or restores (`isActive: true`) an employee
  /// without breaking historical FK references.
  Future<Result<Employee>> setEmployeeActive({
    required String id,
    required bool isActive,
    String? actorEmployeeId,
  });

  /// Deletes an employee only if no orders, stock movements, deliveries,
  /// payments, or expenses reference them (`ON DELETE RESTRICT` ->
  /// `ConflictFailure` if referenced).
  Future<Result<void>> deleteEmployee(
    String id, {
    String? actorEmployeeId,
  });
}
