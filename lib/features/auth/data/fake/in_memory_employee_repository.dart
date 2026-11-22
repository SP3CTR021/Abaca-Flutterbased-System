import '../../../../core/data/fake/in_memory_database.dart';
import '../../../../core/data/input_validators.dart';
import '../../../../core/errors/app_failure.dart';
import '../../../../core/result/result.dart';
import '../../../audit/domain/entities/activity_log.dart';
import '../../../audit/domain/entities/audit_enums.dart';
import '../../domain/entities/employee.dart';
import '../../domain/entities/employee_role.dart';
import '../../domain/repositories/employee_repository.dart';

/// Pure-Dart in-memory implementation of [EmployeeRepository].
final class InMemoryEmployeeRepository implements EmployeeRepository {
  InMemoryEmployeeRepository(this._db);

  final InMemoryDatabase _db;

  @override
  Future<Result<Employee>> getEmployeeById(String id) async {
    final emp = _db.employees[id];
    if (emp == null) {
      return Err<Employee>(
        NotFoundFailure(
          entityName: 'Employee',
          entityId: id,
          message: 'Employee $id was not found.',
        ),
      );
    }
    return Ok<Employee>(emp);
  }

  @override
  Future<Result<Employee?>> getEmployeeByEmail(String email) async {
    final normalized = email.trim().toLowerCase();
    if (normalized.isEmpty) return const Ok<Employee?>(null);

    for (final emp in _db.employees.values) {
      if (emp.email.toLowerCase() == normalized) {
        return Ok<Employee?>(emp);
      }
    }
    return const Ok<Employee?>(null);
  }

  @override
  Future<Result<List<Employee>>> getEmployees({
    EmployeeRole? role,
    bool? isActive,
  }) async =>
      Ok<List<Employee>>(_filterEmployees(role: role, isActive: isActive));

  @override
  Stream<List<Employee>> watchEmployees({
    EmployeeRole? role,
    bool? isActive,
  }) =>
      _db.watch(() => _filterEmployees(role: role, isActive: isActive));

  @override
  Future<Result<Employee>> updateEmployee(
    Employee employee, {
    String? actorEmployeeId,
  }) async {
    final errors = <String, String>{};
    InputValidators.requireNonEmpty(errors, 'firstName', employee.firstName);
    InputValidators.requireNonEmpty(errors, 'lastName', employee.lastName);
    InputValidators.validateEmail(errors, 'email', employee.email);
    final validation = InputValidators.toFailure(errors);
    if (validation != null) return Err<Employee>(validation);

    final existing = _db.employees[employee.id];
    if (existing == null) {
      return Err<Employee>(
        NotFoundFailure(
          entityName: 'Employee',
          entityId: employee.id,
          message: 'Employee ${employee.id} was not found.',
        ),
      );
    }

    final normalizedEmail = employee.email.trim().toLowerCase();
    final duplicate = _db.employees.values.any(
      (other) =>
          other.id != employee.id &&
          other.email.toLowerCase() == normalizedEmail,
    );
    if (duplicate) {
      return Err<Employee>(
        ConflictFailure(
          message: 'Email "$normalizedEmail" is already in use.',
          code: 'unique_violation',
        ),
      );
    }

    final now = _db.nextTimestamp();
    final trimmedMiddle = employee.middleName?.trim();
    final updated = employee.copyWith(
      firstName: employee.firstName.trim(),
      middleName:
          (trimmedMiddle == null || trimmedMiddle.isEmpty) ? null : trimmedMiddle,
      clearMiddleName: trimmedMiddle == null || trimmedMiddle.isEmpty,
      lastName: employee.lastName.trim(),
      email: normalizedEmail,
      createdAt: existing.createdAt,
      updatedAt: now,
    );
    _db.employees[updated.id] = updated;
    _db.recordAudit(
      actorEmployeeId: actorEmployeeId,
      action: AuditAction.updated,
      entityType: AuditEntityType.employee,
      entityId: updated.id,
      description: 'Updated employee ${updated.fullName}.',
      oldValues: <String, Object?>{
        'role': existing.role.dbValue,
        'is_active': existing.isActive,
      },
      newValues: <String, Object?>{
        'role': updated.role.dbValue,
        'is_active': updated.isActive,
      },
      createdAt: now,
    );
    _db.notify();
    return Ok<Employee>(updated);
  }

  @override
  Future<Result<Employee>> setEmployeeActive({
    required String id,
    required bool isActive,
    String? actorEmployeeId,
  }) async {
    final existing = _db.employees[id];
    if (existing == null) {
      return Err<Employee>(
        NotFoundFailure(
          entityName: 'Employee',
          entityId: id,
          message: 'Employee $id was not found.',
        ),
      );
    }

    final now = _db.nextTimestamp();
    final updated = existing.copyWith(isActive: isActive, updatedAt: now);
    _db.employees[id] = updated;
    _db.recordAudit(
      actorEmployeeId: actorEmployeeId,
      action: isActive ? AuditAction.restored : AuditAction.archived,
      entityType: AuditEntityType.employee,
      entityId: id,
      description: isActive
          ? 'Restored employee ${updated.fullName}.'
          : 'Archived employee ${updated.fullName}.',
      createdAt: now,
    );
    _db.notify();
    return Ok<Employee>(updated);
  }

  @override
  Future<Result<void>> deleteEmployee(
    String id, {
    String? actorEmployeeId,
  }) async {
    final existing = _db.employees[id];
    if (existing == null) {
      return Err<void>(
        NotFoundFailure(
          entityName: 'Employee',
          entityId: id,
          message: 'Employee $id was not found.',
        ),
      );
    }

    final isReferenced = _db.orders.values.any((e) => e.employeeId == id) ||
        _db.stockIns.values.any((e) => e.employeeId == id) ||
        _db.stockOuts.values.any((e) => e.employeeId == id) ||
        _db.deliveries.values.any((e) => e.employeeId == id) ||
        _db.payments.values.any((e) => e.employeeId == id) ||
        _db.expenses.values.any((e) => e.employeeId == id);
    if (isReferenced) {
      return const Err<void>(
        ConflictFailure(
          message:
              'Cannot delete employee referenced by operational records. Archive instead.',
          code: 'foreign_key_violation',
        ),
      );
    }

    _db.employees.remove(id);
    _db.passwordsByEmployeeId.remove(id);
    if (_db.currentEmployeeId == id) {
      _db.currentEmployeeId = null;
    }

    // Mirror ON DELETE SET NULL on activity_logs.actor_employee_id.
    for (var i = 0; i < _db.activityLogs.length; i++) {
      final log = _db.activityLogs[i];
      if (log.actorEmployeeId == id) {
        _db.activityLogs[i] = ActivityLog(
          id: log.id,
          actorEmployeeId: null,
          action: log.action,
          entityType: log.entityType,
          entityId: log.entityId,
          description: log.description,
          oldValues: log.oldValues,
          newValues: log.newValues,
          createdAt: log.createdAt,
        );
      }
    }

    _db.recordAudit(
      actorEmployeeId: actorEmployeeId == id ? null : actorEmployeeId,
      action: AuditAction.deleted,
      entityType: AuditEntityType.employee,
      entityId: id,
      description: 'Deleted employee ${existing.fullName}.',
    );
    _db.notify();
    return const Ok<void>(null);
  }

  List<Employee> _filterEmployees({EmployeeRole? role, bool? isActive}) {
    final list = _db.employees.values.where((emp) {
      if (role != null && emp.role != role) return false;
      if (isActive != null && emp.isActive != isActive) return false;
      return true;
    }).toList()
      ..sort((a, b) {
        final lastCmp = a.lastName.compareTo(b.lastName);
        return lastCmp != 0 ? lastCmp : a.firstName.compareTo(b.firstName);
      });
    return List<Employee>.unmodifiable(list);
  }
}
