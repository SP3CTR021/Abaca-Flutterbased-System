import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/data/input_validators.dart';
import '../../../../core/data/supabase/supabase_helpers.dart';
import '../../../../core/errors/app_failure.dart';
import '../../../../core/result/result.dart';
import '../../../audit/data/supabase/supabase_audit_repository.dart';
import '../../../audit/domain/entities/audit_enums.dart';
import '../../domain/entities/supplier.dart';
import '../../domain/repositories/supplier_repository.dart';
import 'supplier_supabase_dto.dart';

/// PostgreSQL / Supabase implementation of [SupplierRepository].
final class SupabaseSupplierRepository implements SupplierRepository {
  SupabaseSupplierRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<Result<Supplier>> createSupplier({
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
    if (validation != null) return Err<Supplier>(validation);

    try {
      final row = await _client
          .from(SupplierSupabaseDto.tableName)
          .insert(
            SupplierSupabaseDto.toInsertMap(
              firstName: firstName,
              middleName: middleName,
              lastName: lastName,
              contactNumber: contactNumber,
              address: address,
            ),
          )
          .select()
          .single();

      final created = SupplierSupabaseDto.fromSupabase(row);
      await SupabaseAuditRepository.tryRecordAudit(
        _client,
        actorEmployeeId: actorEmployeeId,
        action: AuditAction.created,
        entityType: AuditEntityType.supplier,
        entityId: created.id,
        description: 'Created supplier ${created.fullName}.',
      );
      return Ok<Supplier>(created);
    } catch (error) {
      return Err<Supplier>(
        SupabaseHelpers.mapError(error, entityName: 'Supplier'),
      );
    }
  }

  @override
  Future<Result<Supplier>> getSupplierById(String id) async {
    try {
      final row = await _client
          .from(SupplierSupabaseDto.tableName)
          .select()
          .eq('supplier_id', id)
          .maybeSingle();

      if (row == null) {
        return Err<Supplier>(
          NotFoundFailure(
            entityName: 'Supplier',
            entityId: id,
            message: 'Supplier $id was not found.',
          ),
        );
      }
      return Ok<Supplier>(SupplierSupabaseDto.fromSupabase(row));
    } catch (error) {
      return Err<Supplier>(
        SupabaseHelpers.mapError(error, entityName: 'Supplier', entityId: id),
      );
    }
  }

  @override
  Future<Result<List<Supplier>>> getSuppliers({
    bool? isActive,
    String? searchQuery,
  }) async {
    try {
      var query = _client.from(SupplierSupabaseDto.tableName).select();
      if (isActive != null) {
        query = query.eq('is_active', isActive);
      }

      final trimmedQuery = searchQuery?.trim() ?? '';
      if (trimmedQuery.isNotEmpty) {
        // Server-side ILIKE on first token narrows candidate rows, followed by
        // full-name matching so multi-word queries ("Juan Cruz") also work.
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

      var suppliers = rows.map(SupplierSupabaseDto.fromSupabase).toList();
      if (trimmedQuery.isNotEmpty) {
        final needle = trimmedQuery.toLowerCase();
        suppliers = suppliers.where((supplier) {
          return supplier.fullName.toLowerCase().contains(needle) ||
              (supplier.contactNumber?.toLowerCase().contains(needle) ??
                  false) ||
              (supplier.address?.toLowerCase().contains(needle) ?? false);
        }).toList(growable: false);
      }
      return Ok<List<Supplier>>(suppliers);
    } catch (error) {
      return Err<List<Supplier>>(
        SupabaseHelpers.mapError(error, entityName: 'Supplier'),
      );
    }
  }

  @override
  Stream<List<Supplier>> watchSuppliers({bool? isActive}) {
    final base = _client
        .from(SupplierSupabaseDto.tableName)
        .stream(primaryKey: const <String>['supplier_id']);

    final filtered =
        isActive != null ? base.eq('is_active', isActive) : base;

    return filtered.order('last_name', ascending: true).map(
          (rows) => rows
              .map(SupplierSupabaseDto.fromSupabase)
              .toList(growable: false),
        );
  }

  @override
  Future<Result<Supplier>> updateSupplier(
    Supplier supplier, {
    String? actorEmployeeId,
  }) async {
    final errors = <String, String>{};
    InputValidators.requireNonEmpty(errors, 'firstName', supplier.firstName);
    InputValidators.requireNonEmpty(errors, 'lastName', supplier.lastName);
    InputValidators.validateMaxLength(
      errors,
      'address',
      supplier.address,
      500,
    );
    final validation = InputValidators.toFailure(errors);
    if (validation != null) return Err<Supplier>(validation);

    try {
      final row = await _client
          .from(SupplierSupabaseDto.tableName)
          .update(SupplierSupabaseDto.toUpdateMap(supplier))
          .eq('supplier_id', supplier.id)
          .select()
          .maybeSingle();

      if (row == null) {
        return Err<Supplier>(
          NotFoundFailure(
            entityName: 'Supplier',
            entityId: supplier.id,
            message: 'Supplier ${supplier.id} was not found.',
          ),
        );
      }

      final updated = SupplierSupabaseDto.fromSupabase(row);
      await SupabaseAuditRepository.tryRecordAudit(
        _client,
        actorEmployeeId: actorEmployeeId,
        action: AuditAction.updated,
        entityType: AuditEntityType.supplier,
        entityId: updated.id,
        description: 'Updated supplier ${updated.fullName}.',
      );
      return Ok<Supplier>(updated);
    } catch (error) {
      return Err<Supplier>(
        SupabaseHelpers.mapError(
          error,
          entityName: 'Supplier',
          entityId: supplier.id,
        ),
      );
    }
  }

  @override
  Future<Result<Supplier>> setSupplierActive({
    required String id,
    required bool isActive,
    String? actorEmployeeId,
  }) async {
    try {
      final row = await _client
          .from(SupplierSupabaseDto.tableName)
          .update(<String, dynamic>{'is_active': isActive})
          .eq('supplier_id', id)
          .select()
          .maybeSingle();

      if (row == null) {
        return Err<Supplier>(
          NotFoundFailure(
            entityName: 'Supplier',
            entityId: id,
            message: 'Supplier $id was not found.',
          ),
        );
      }

      final updated = SupplierSupabaseDto.fromSupabase(row);
      await SupabaseAuditRepository.tryRecordAudit(
        _client,
        actorEmployeeId: actorEmployeeId,
        action: isActive ? AuditAction.restored : AuditAction.archived,
        entityType: AuditEntityType.supplier,
        entityId: id,
        description: isActive
            ? 'Restored supplier ${updated.fullName}.'
            : 'Archived supplier ${updated.fullName}.',
      );
      return Ok<Supplier>(updated);
    } catch (error) {
      return Err<Supplier>(
        SupabaseHelpers.mapError(error, entityName: 'Supplier', entityId: id),
      );
    }
  }

  @override
  Future<Result<void>> deleteSupplier(
    String id, {
    String? actorEmployeeId,
  }) async {
    try {
      final existing = await getSupplierById(id);
      if (existing.isErr) return Err<void>(existing.failureOrNull!);

      // Postgres ON DELETE RESTRICT protects stock_ins (23503 -> ConflictFailure).
      await _client
          .from(SupplierSupabaseDto.tableName)
          .delete()
          .eq('supplier_id', id);

      await SupabaseAuditRepository.tryRecordAudit(
        _client,
        actorEmployeeId: actorEmployeeId,
        action: AuditAction.deleted,
        entityType: AuditEntityType.supplier,
        entityId: id,
        description: 'Deleted supplier ${existing.valueOrNull?.fullName ?? id}.',
      );
      return const Ok<void>(null);
    } catch (error) {
      return Err<void>(
        SupabaseHelpers.mapError(error, entityName: 'Supplier', entityId: id),
      );
    }
  }
}
