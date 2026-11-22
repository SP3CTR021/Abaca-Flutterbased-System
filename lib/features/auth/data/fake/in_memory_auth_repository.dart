import '../../../../core/data/fake/in_memory_database.dart';
import '../../../../core/data/input_validators.dart';
import '../../../../core/errors/app_failure.dart';
import '../../../../core/result/result.dart';
import '../../../audit/domain/entities/audit_enums.dart';
import '../../domain/entities/employee.dart';
import '../../domain/entities/employee_role.dart';
import '../../domain/repositories/auth_repository.dart';

/// Pure-Dart in-memory implementation of [AuthRepository].
final class InMemoryAuthRepository implements AuthRepository {
  InMemoryAuthRepository(this._db);

  final InMemoryDatabase _db;

  @override
  Future<Result<Employee>> signInWithEmailAndPassword({
    required String email,
    required String password,
  }) async {
    final errors = <String, String>{};
    InputValidators.validateEmail(errors, 'email', email);
    InputValidators.requireNonEmpty(errors, 'password', password);
    final validation = InputValidators.toFailure(errors);
    if (validation != null) return Err<Employee>(validation);

    final normalized = email.trim().toLowerCase();
    Employee? match;
    for (final emp in _db.employees.values) {
      if (emp.email.toLowerCase() == normalized) {
        match = emp;
        break;
      }
    }

    if (match == null || _db.passwordsByEmployeeId[match.id] != password) {
      return const Err<Employee>(
        UnauthorizedFailure(message: 'Invalid email or password.'),
      );
    }

    if (!match.isActive) {
      return const Err<Employee>(
        PermissionDeniedFailure(
          message: 'This employee account has been archived.',
        ),
      );
    }

    _db.currentEmployeeId = match.id;
    _db.recordAudit(
      actorEmployeeId: match.id,
      action: AuditAction.signedIn,
      entityType: AuditEntityType.auth,
      entityId: match.id,
      description: '${match.fullName} signed in.',
    );
    _db.notify();
    return Ok<Employee>(match);
  }

  @override
  Future<Result<void>> signOut() async {
    final activeId = _db.currentEmployeeId;
    if (activeId != null) {
      _db.recordAudit(
        actorEmployeeId: activeId,
        action: AuditAction.signedOut,
        entityType: AuditEntityType.auth,
        entityId: activeId,
        description: 'Employee signed out.',
      );
    }
    _db.currentEmployeeId = null;
    _db.notify();
    return const Ok<void>(null);
  }

  @override
  Future<Result<Employee?>> getCurrentEmployee() async {
    final activeId = _db.currentEmployeeId;
    if (activeId == null) return const Ok<Employee?>(null);
    return Ok<Employee?>(_db.employees[activeId]);
  }

  @override
  Stream<Employee?> watchAuthState() => _db
      .watch(
        () => _db.currentEmployeeId == null
            ? null
            : _db.employees[_db.currentEmployeeId!],
      )
      .distinct();

  @override
  Future<Result<Employee>> registerEmployee({
    required String firstName,
    String? middleName,
    required String lastName,
    required String email,
    required String password,
    required EmployeeRole role,
    String? actorEmployeeId,
  }) async {
    final errors = <String, String>{};
    InputValidators.requireNonEmpty(errors, 'firstName', firstName);
    InputValidators.requireNonEmpty(errors, 'lastName', lastName);
    InputValidators.validateEmail(errors, 'email', email);
    if (password.length < 6) {
      errors['password'] = 'Password must be at least 6 characters.';
    }
    final validation = InputValidators.toFailure(errors);
    if (validation != null) return Err<Employee>(validation);

    final normalized = email.trim().toLowerCase();
    final duplicate = _db.employees.values.any(
      (emp) => emp.email.toLowerCase() == normalized,
    );
    if (duplicate) {
      return Err<Employee>(
        ConflictFailure(
          message: 'Email "$normalized" is already registered.',
          code: 'email_already_in_use',
        ),
      );
    }

    final now = _db.nextTimestamp();
    final id = _db.nextId();
    final trimmedMiddle = middleName?.trim();
    final created = Employee(
      id: id,
      firstName: firstName.trim(),
      middleName:
          (trimmedMiddle == null || trimmedMiddle.isEmpty) ? null : trimmedMiddle,
      lastName: lastName.trim(),
      email: normalized,
      role: role,
      isActive: true,
      createdAt: now,
      updatedAt: now,
    );

    _db.employees[id] = created;
    _db.passwordsByEmployeeId[id] = password;
    // Mirror Supabase/Firestore: keep active manager signed in when creating staff.
    _db.currentEmployeeId ??= id;

    _db.recordAudit(
      actorEmployeeId: actorEmployeeId ?? id,
      action: AuditAction.created,
      entityType: AuditEntityType.employee,
      entityId: id,
      description:
          'Registered employee ${created.fullName} (${created.role.dbValue}).',
      newValues: <String, Object?>{
        'email': created.email,
        'role': created.role.dbValue,
      },
      createdAt: now,
    );
    _db.notify();
    return Ok<Employee>(created);
  }

  @override
  Future<Result<void>> sendPasswordResetEmail(String email) async {
    final errors = <String, String>{};
    InputValidators.validateEmail(errors, 'email', email);
    final validation = InputValidators.toFailure(errors);
    if (validation != null) return Err<void>(validation);
    return const Ok<void>(null);
  }
}
