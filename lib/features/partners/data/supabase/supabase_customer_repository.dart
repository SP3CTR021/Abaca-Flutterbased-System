import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/data/input_validators.dart';
import '../../../../core/data/supabase/supabase_helpers.dart';
import '../../../../core/errors/app_failure.dart';
import '../../../../core/result/result.dart';
import '../../../audit/data/supabase/supabase_audit_repository.dart';
import '../../../audit/domain/entities/audit_enums.dart';
import '../../domain/entities/customer.dart';
import '../../domain/repositories/customer_repository.dart';
import 'customer_supabase_dto.dart';

/// PostgreSQL / Supabase implementation of [CustomerRepository].
final class SupabaseCustomerRepository implements CustomerRepository {
  SupabaseCustomerRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<Result<Customer>> createCustomer({
    required String firstName,
    String? middleName,
    required String lastName,
    String? contactNumber,
    String? address,
    String? actorEmployeeId,
  }) async {
    final errors = <String, String>{};
    InputValidators.requireNonEmpty(errors, 'firstName', firstName);
    InputValidators.requireNonEmpty(errors, 'lastName', lastName);
    InputValidators.validateMaxLength(errors, 'address', address, 500);
    final validation = InputValidators.toFailure(errors);
    if (validation != null) return Err<Customer>(validation);

    try {
      final row = await _client
          .from(CustomerSupabaseDto.tableName)
          .insert(
            CustomerSupabaseDto.toInsertMap(
              firstName: firstName,
              middleName: middleName,
              lastName: lastName,
              contactNumber: contactNumber,
              address: address,
            ),
          )
          .select()
          .single();

      final created = CustomerSupabaseDto.fromSupabase(row);
      await SupabaseAuditRepository.tryRecordAudit(
        _client,
        actorEmployeeId: actorEmployeeId,
        action: AuditAction.created,
        entityType: AuditEntityType.customer,
        entityId: created.id,
        description: 'Created customer ${created.fullName}.',
      );
      return Ok<Customer>(created);
    } catch (error) {
      return Err<Customer>(
        SupabaseHelpers.mapError(error, entityName: 'Customer'),
      );
    }
  }

  @override
  Future<Result<Customer>> getCustomerById(String id) async {
    try {
      final row = await _client
          .from(CustomerSupabaseDto.tableName)
          .select()
          .eq('customer_id', id)
          .maybeSingle();

      if (row == null) {
        return Err<Customer>(
          NotFoundFailure(
            entityName: 'Customer',
            entityId: id,
            message: 'Customer $id was not found.',
          ),
        );
      }
      return Ok<Customer>(CustomerSupabaseDto.fromSupabase(row));
    } catch (error) {
      return Err<Customer>(
        SupabaseHelpers.mapError(error, entityName: 'Customer', entityId: id),
      );
    }
  }

  @override
  Future<Result<List<Customer>>> getCustomers({
    bool? isActive,
    String? searchQuery,
  }) async {
    try {
      var query = _client.from(CustomerSupabaseDto.tableName).select();
      if (isActive != null) {
        query = query.eq('is_active', isActive);
      }

      final trimmedQuery = searchQuery?.trim() ?? '';
      if (trimmedQuery.isNotEmpty) {
        final firstToken = trimmedQuery
            .split(RegExp(r'\s+'))
            .first
            .replaceAll(RegExp(r'[,()%]'), '');
        if (firstToken.isNotEmpty) {
          query = query.or(
            'first_name.ilike.%$firstToken%,'
            'middle_name.ilike.%$firstToken%,'
            'last_name.ilike.%$firstToken%,'
            'contact_number.ilike.%$firstToken%',
          );
        }
      }

      final rows = await query
          .order('last_name', ascending: true)
          .order('first_name', ascending: true);

      var customers = rows.map(CustomerSupabaseDto.fromSupabase).toList();
      if (trimmedQuery.isNotEmpty) {
        final needle = trimmedQuery.toLowerCase();
        customers = customers.where((customer) {
          return customer.fullName.toLowerCase().contains(needle) ||
              (customer.contactNumber?.toLowerCase().contains(needle) ??
                  false) ||
              (customer.address?.toLowerCase().contains(needle) ?? false);
        }).toList(growable: false);
      }
      return Ok<List<Customer>>(customers);
    } catch (error) {
      return Err<List<Customer>>(
        SupabaseHelpers.mapError(error, entityName: 'Customer'),
      );
    }
  }

  @override
  Stream<List<Customer>> watchCustomers({bool? isActive}) {
    final base = _client
        .from(CustomerSupabaseDto.tableName)
        .stream(primaryKey: const <String>['customer_id']);

    final filtered =
        isActive != null ? base.eq('is_active', isActive) : base;

    return filtered.order('last_name', ascending: true).map(
          (rows) => rows
              .map(CustomerSupabaseDto.fromSupabase)
              .toList(growable: false),
        );
  }

  @override
  Future<Result<Customer>> updateCustomer(
    Customer customer, {
    String? actorEmployeeId,
  }) async {
    final errors = <String, String>{};
    InputValidators.requireNonEmpty(errors, 'firstName', customer.firstName);
    InputValidators.requireNonEmpty(errors, 'lastName', customer.lastName);
    InputValidators.validateMaxLength(
      errors,
      'address',
      customer.address,
      500,
    );
    final validation = InputValidators.toFailure(errors);
    if (validation != null) return Err<Customer>(validation);

    try {
      final row = await _client
          .from(CustomerSupabaseDto.tableName)
          .update(CustomerSupabaseDto.toUpdateMap(customer))
          .eq('customer_id', customer.id)
          .select()
          .maybeSingle();

      if (row == null) {
        return Err<Customer>(
          NotFoundFailure(
            entityName: 'Customer',
            entityId: customer.id,
            message: 'Customer ${customer.id} was not found.',
          ),
        );
      }

      final updated = CustomerSupabaseDto.fromSupabase(row);
      await SupabaseAuditRepository.tryRecordAudit(
        _client,
        actorEmployeeId: actorEmployeeId,
        action: AuditAction.updated,
        entityType: AuditEntityType.customer,
        entityId: updated.id,
        description: 'Updated customer ${updated.fullName}.',
      );
      return Ok<Customer>(updated);
    } catch (error) {
      return Err<Customer>(
        SupabaseHelpers.mapError(
          error,
          entityName: 'Customer',
          entityId: customer.id,
        ),
      );
    }
  }

  @override
  Future<Result<Customer>> setCustomerActive({
    required String id,
    required bool isActive,
    String? actorEmployeeId,
  }) async {
    try {
      final row = await _client
          .from(CustomerSupabaseDto.tableName)
          .update(<String, dynamic>{'is_active': isActive})
          .eq('customer_id', id)
          .select()
          .maybeSingle();

      if (row == null) {
        return Err<Customer>(
          NotFoundFailure(
            entityName: 'Customer',
            entityId: id,
            message: 'Customer $id was not found.',
          ),
        );
      }

      final updated = CustomerSupabaseDto.fromSupabase(row);
      await SupabaseAuditRepository.tryRecordAudit(
        _client,
        actorEmployeeId: actorEmployeeId,
        action: isActive ? AuditAction.restored : AuditAction.archived,
        entityType: AuditEntityType.customer,
        entityId: id,
        description: isActive
            ? 'Restored customer ${updated.fullName}.'
            : 'Archived customer ${updated.fullName}.',
      );
      return Ok<Customer>(updated);
    } catch (error) {
      return Err<Customer>(
        SupabaseHelpers.mapError(error, entityName: 'Customer', entityId: id),
      );
    }
  }

  @override
  Future<Result<void>> deleteCustomer(
    String id, {
    String? actorEmployeeId,
  }) async {
    try {
      final existing = await getCustomerById(id);
      if (existing.isErr) return Err<void>(existing.failureOrNull!);

      // Postgres ON DELETE RESTRICT protects orders (23503 -> ConflictFailure).
      await _client
          .from(CustomerSupabaseDto.tableName)
          .delete()
          .eq('customer_id', id);

      await SupabaseAuditRepository.tryRecordAudit(
        _client,
        actorEmployeeId: actorEmployeeId,
        action: AuditAction.deleted,
        entityType: AuditEntityType.customer,
        entityId: id,
        description: 'Deleted customer ${existing.valueOrNull?.fullName ?? id}.',
      );
      return const Ok<void>(null);
    } catch (error) {
      return Err<void>(
        SupabaseHelpers.mapError(error, entityName: 'Customer', entityId: id),
      );
    }
  }
}
