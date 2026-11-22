import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/data/input_validators.dart';
import '../../../../core/data/supabase/supabase_helpers.dart';
import '../../../../core/errors/app_failure.dart';
import '../../../../core/result/result.dart';
import '../../../audit/data/supabase/supabase_audit_repository.dart';
import '../../../audit/domain/entities/audit_enums.dart';
import '../../domain/entities/employee.dart';
import '../../domain/entities/employee_role.dart';
import '../../domain/repositories/auth_repository.dart';
import 'employee_supabase_dto.dart';

/// Supabase GoTrue + `employees` implementation of [AuthRepository].
final class SupabaseAuthRepository implements AuthRepository {
  SupabaseAuthRepository(
    this._client, {
    this._supabaseUrl,
    this._supabasePublishableKey,
  });

  final SupabaseClient _client;
  final String? _supabaseUrl;
  final String? _supabasePublishableKey;

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

    try {
      final response = await _client.auth.signInWithPassword(
        email: email.trim(),
        password: password,
      );
      final user = response.user;
      if (user == null) {
        return const Err<Employee>(
          UnauthorizedFailure(message: 'Authentication failed.'),
        );
      }

      final row = await _client
          .from(EmployeeSupabaseDto.tableName)
          .select()
          .eq('employee_id', user.id)
          .single();

      final employee = EmployeeSupabaseDto.fromSupabase(row);
      if (!employee.isActive) {
        await _client.auth.signOut();
        return const Err<Employee>(
          PermissionDeniedFailure(
            message: 'This employee account has been archived.',
          ),
        );
      }

      await SupabaseAuditRepository.tryRecordAudit(
        _client,
        actorEmployeeId: employee.id,
        action: AuditAction.signedIn,
        entityType: AuditEntityType.auth,
        entityId: employee.id,
        description: '${employee.fullName} signed in.',
      );

      return Ok<Employee>(employee);
    } catch (error) {
      return Err<Employee>(
        SupabaseHelpers.mapError(error, entityName: 'Employee'),
      );
    }
  }

  @override
  Future<Result<void>> signOut() async {
    try {
      final currentId = _client.auth.currentUser?.id;
      if (currentId != null) {
        await SupabaseAuditRepository.tryRecordAudit(
          _client,
          actorEmployeeId: currentId,
          action: AuditAction.signedOut,
          entityType: AuditEntityType.auth,
          entityId: currentId,
          description: 'Employee signed out.',
        );
      }
      await _client.auth.signOut();
      return const Ok<void>(null);
    } catch (error) {
      return Err<void>(SupabaseHelpers.mapError(error, entityName: 'Auth'));
    }
  }

  @override
  Future<Result<Employee?>> getCurrentEmployee() async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) return const Ok<Employee?>(null);

      final row = await _client
          .from(EmployeeSupabaseDto.tableName)
          .select()
          .eq('employee_id', user.id)
          .maybeSingle();

      if (row == null) return const Ok<Employee?>(null);
      return Ok<Employee?>(EmployeeSupabaseDto.fromSupabase(row));
    } catch (error) {
      return Err<Employee?>(
        SupabaseHelpers.mapError(error, entityName: 'Employee'),
      );
    }
  }

  @override
  Stream<Employee?> watchAuthState() async* {
    final initial = await getCurrentEmployee();
    yield initial.valueOrNull;

    await for (final authState in _client.auth.onAuthStateChange.handleError(
      (Object _) {},
    )) {
      final user = authState.session?.user;
      if (user == null) {
        yield null;
        continue;
      }
      try {
        final row = await _client
            .from(EmployeeSupabaseDto.tableName)
            .select()
            .eq('employee_id', user.id)
            .maybeSingle();
        yield row == null ? null : EmployeeSupabaseDto.fromSupabase(row);
      } catch (_) {
        yield null;
      }
    }
  }

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

    final hasActiveManagerSession = _client.auth.currentSession != null;
    SupabaseClient? ephemeralClient;

    try {
      // When a manager registers a new employee, sign up via a disposable
      // client so the manager's active session is not replaced.
      final authClient =
          (hasActiveManagerSession &&
                  _supabaseUrl != null &&
                  _supabasePublishableKey != null)
              ? (ephemeralClient = SupabaseClient(
                  _supabaseUrl,
                  _supabasePublishableKey,
                  authOptions: const AuthClientOptions(autoRefreshToken: false),
                ))
              : _client;

      final authResponse = await authClient.auth.signUp(
        email: email.trim().toLowerCase(),
        password: password,
      );
      final user = authResponse.user;
      if (user == null) {
        return const Err<Employee>(
          UnknownFailure(message: 'Failed to create auth user account.'),
        );
      }

      // Use the manager's authenticated client when available so RLS allows
      // inserting another employee's profile row.
      final dbClient = hasActiveManagerSession ? _client : authClient;
      final row = await dbClient
          .from(EmployeeSupabaseDto.tableName)
          .insert(
            EmployeeSupabaseDto.toInsertMap(
              employeeId: user.id,
              firstName: firstName,
              middleName: middleName,
              lastName: lastName,
              email: email,
              role: role,
            ),
          )
          .select()
          .single();

      final created = EmployeeSupabaseDto.fromSupabase(row);
      await SupabaseAuditRepository.tryRecordAudit(
        dbClient,
        actorEmployeeId: actorEmployeeId ?? created.id,
        action: AuditAction.created,
        entityType: AuditEntityType.employee,
        entityId: created.id,
        description:
            'Registered employee ${created.fullName} (${created.role.dbValue}).',
        newValues: <String, Object?>{
          'email': created.email,
          'role': created.role.dbValue,
        },
      );

      return Ok<Employee>(created);
    } catch (error) {
      return Err<Employee>(
        SupabaseHelpers.mapError(error, entityName: 'Employee'),
      );
    } finally {
      if (ephemeralClient != null) {
        await ephemeralClient.dispose();
      }
    }
  }

  @override
  Future<Result<void>> sendPasswordResetEmail(String email) async {
    final errors = <String, String>{};
    InputValidators.validateEmail(errors, 'email', email);
    final validation = InputValidators.toFailure(errors);
    if (validation != null) return Err<void>(validation);

    try {
      await _client.auth.resetPasswordForEmail(email.trim());
      return const Ok<void>(null);
    } catch (error) {
      return Err<void>(SupabaseHelpers.mapError(error, entityName: 'Auth'));
    }
  }
}
