import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/data/input_validators.dart';
import '../../../../core/data/supabase/supabase_helpers.dart';
import '../../../../core/errors/app_failure.dart';
import '../../../../core/result/result.dart';
import '../../../audit/data/supabase/supabase_audit_repository.dart';
import '../../../audit/domain/entities/audit_enums.dart';
import '../../domain/entities/employee.dart';
import '../../domain/entities/employee_role.dart';
import '../../domain/repositories/employee_repository.dart';
import 'employee_supabase_dto.dart';

/// PostgreSQL / Supabase implementation of [EmployeeRepository].
final class SupabaseEmployeeRepository implements EmployeeRepository {
  SupabaseEmployeeRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<Result<Employee>> getEmployeeById(String id) async {
    try {
      final row = await _client
          .from(EmployeeSupabaseDto.tableName)
          .select()
          .eq('employee_id', id)
          .maybeSingle();

      if (row == null) {
        return Err<Employee>(
          NotFoundFailure(
            entityName: 'Employee',
            entityId: id,
            message: 'Employee $id was not found.',
          ),
        );
      }
      return Ok<Employee>(EmployeeSupabaseDto.fromSupabase(row));
    } catch (error) {
      return Err<Employee>(
        SupabaseHelpers.mapError(error, entityName: 'Employee', entityId: id),
      );
    }
  }

  @override
  Future<Result<Employee?>> getEmployeeByEmail(String email) async {
    final normalized = email.trim().toLowerCase();
    if (normalized.isEmpty) return const Ok<Employee?>(null);

    try {
      final row = await _client
          .from(EmployeeSupabaseDto.tableName)
          .select()
          .ilike('email', normalized)
          .maybeSingle();

      return Ok<Employee?>(
        row == null ? null : EmployeeSupabaseDto.fromSupabase(row),
      );
    } catch (error) {
      return Err<Employee?>(
        SupabaseHelpers.mapError(error, entityName: 'Employee'),
      );
    }
  }

  @override
  Future<Result<List<Employee>>> getEmployees({
    EmployeeRole? role,
    bool? isActive,
  }) async {
    try {
      var query = _client.from(EmployeeSupabaseDto.tableName).select();
      if (role != null) {
        query = query.eq('role', role.dbValue);
      }
      if (isActive != null) {
        query = query.eq('is_active', isActive);
      }

      final rows = await query
          .order('last_name', ascending: true)
          .order('first_name', ascending: true);

      return Ok<List<Employee>>(
        rows.map(EmployeeSupabaseDto.fromSupabase).toList(growable: false),
      );
    } catch (error) {
      return Err<List<Employee>>(
        SupabaseHelpers.mapError(error, entityName: 'Employee'),
      );
    }
  }

  @override
  Stream<List<Employee>> watchEmployees({
    EmployeeRole? role,
    bool? isActive,
  }) {
    final base = _client
        .from(EmployeeSupabaseDto.tableName)
        .stream(primaryKey: const <String>['employee_id']);

    final filtered = role != null
        ? base.eq('role', role.dbValue)
        : (isActive != null ? base.eq('is_active', isActive) : base);

    return filtered.order('last_name', ascending: true).map((rows) {
      var list = rows.map(EmployeeSupabaseDto.fromSupabase);
      if (role != null && isActive != null) {
        list = list.where((e) => e.isActive == isActive);
      }
      return list.toList(growable: false);
    });
  }

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

    try {
      final previous = await getEmployeeById(employee.id);
      if (previous.isErr) return previous;

      final row = await _client
          .from(EmployeeSupabaseDto.tableName)
          .update(EmployeeSupabaseDto.toUpdateMap(employee))
          .eq('employee_id', employee.id)
          .select()
          .single();

      final updated = EmployeeSupabaseDto.fromSupabase(row);
      await SupabaseAuditRepository.tryRecordAudit(
        _client,
        actorEmployeeId: actorEmployeeId,
        action: AuditAction.updated,
        entityType: AuditEntityType.employee,
        entityId: updated.id,
        description: 'Updated employee ${updated.fullName}.',
        oldValues: <String, Object?>{
          'role': previous.valueOrNull?.role.dbValue,
          'is_active': previous.valueOrNull?.isActive,
        },
        newValues: <String, Object?>{
          'role': updated.role.dbValue,
          'is_active': updated.isActive,
        },
      );
      return Ok<Employee>(updated);
    } catch (error) {
      return Err<Employee>(
        SupabaseHelpers.mapError(
          error,
          entityName: 'Employee',
          entityId: employee.id,
        ),
      );
    }
  }

  @override
  Future<Result<Employee>> setEmployeeActive({
    required String id,
    required bool isActive,
    String? actorEmployeeId,
  }) async {
    try {
      final row = await _client
          .from(EmployeeSupabaseDto.tableName)
          .update(<String, dynamic>{'is_active': isActive})
          .eq('employee_id', id)
          .select()
          .maybeSingle();

      if (row == null) {
        return Err<Employee>(
          NotFoundFailure(
            entityName: 'Employee',
            entityId: id,
            message: 'Employee $id was not found.',
          ),
        );
      }

      final updated = EmployeeSupabaseDto.fromSupabase(row);
      await SupabaseAuditRepository.tryRecordAudit(
        _client,
        actorEmployeeId: actorEmployeeId,
        action: isActive ? AuditAction.restored : AuditAction.archived,
        entityType: AuditEntityType.employee,
        entityId: id,
        description: isActive
            ? 'Restored employee ${updated.fullName}.'
            : 'Archived employee ${updated.fullName}.',
      );
      return Ok<Employee>(updated);
    } catch (error) {
      return Err<Employee>(
        SupabaseHelpers.mapError(error, entityName: 'Employee', entityId: id),
      );
    }
  }

  @override
  Future<Result<void>> deleteEmployee(
    String id, {
    String? actorEmployeeId,
  }) async {
    try {
      final existing = await getEmployeeById(id);
      if (existing.isErr) return Err<void>(existing.failureOrNull!);

      // Postgres ON DELETE RESTRICT protects orders, stock_ins, stock_outs,
      // deliveries, payments, and expenses (mapped to ConflictFailure on 23503).
      await _client
          .from(EmployeeSupabaseDto.tableName)
          .delete()
          .eq('employee_id', id);

      await SupabaseAuditRepository.tryRecordAudit(
        _client,
        actorEmployeeId: actorEmployeeId,
        action: AuditAction.deleted,
        entityType: AuditEntityType.employee,
        entityId: id,
        description: 'Deleted employee ${existing.valueOrNull?.fullName ?? id}.',
      );
      return const Ok<void>(null);
    } catch (error) {
      return Err<void>(
        SupabaseHelpers.mapError(error, entityName: 'Employee', entityId: id),
      );
    }
  }
}
