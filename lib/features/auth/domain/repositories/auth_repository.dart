import '../../../../core/result/result.dart';
import '../entities/employee.dart';
import '../entities/employee_role.dart';

/// Backend-agnostic authentication contract decoupled from `employees` storage.
///
/// Supabase uses `SupabaseAuth` + `employees.employee_id = auth.uid()`;
/// Firestore uses `FirebaseAuth` + `employees/{uid}`.
abstract interface class AuthRepository {
  /// Authenticates an active employee with [email] and [password].
  ///
  /// Returns `PermissionDeniedFailure` if the employee profile is archived
  /// (`isActive == false`), and records a `signedIn` audit entry on success.
  Future<Result<Employee>> signInWithEmailAndPassword({
    required String email,
    required String password,
  });

  /// Signs out the current user and logs `signedOut` when an employee is active.
  Future<Result<void>> signOut();

  /// Fetches the currently signed-in [Employee], or `null` if unauthenticated.
  Future<Result<Employee?>> getCurrentEmployee();

  /// Emits authentication profile changes in real time (`null` when signed out).
  Stream<Employee?> watchAuthState();

  /// Registers a new auth identity and creates its matching `employees` record.
  ///
  /// [actorEmployeeId] records the manager performing the registration in
  /// `activity_logs`.
  Future<Result<Employee>> registerEmployee({
    required String firstName,
    String? middleName,
    required String lastName,
    required String email,
    required String password,
    required EmployeeRole role,
    String? actorEmployeeId,
  });

  /// Sends a backend-native password reset email to [email].
  Future<Result<void>> sendPasswordResetEmail(String email);
}
