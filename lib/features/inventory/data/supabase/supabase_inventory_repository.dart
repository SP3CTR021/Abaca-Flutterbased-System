import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/data/input_validators.dart';
import '../../../../core/data/supabase/supabase_helpers.dart';
import '../../../../core/errors/app_failure.dart';
import '../../../../core/result/result.dart';
import '../../../../core/utils/decimal_precision.dart';
import '../../../audit/data/supabase/supabase_audit_repository.dart';
import '../../../audit/domain/entities/audit_enums.dart';
import '../../domain/entities/inventory.dart';
import '../../domain/repositories/inventory_repository.dart';
import 'inventory_supabase_dto.dart';

/// PostgreSQL / Supabase implementation of [InventoryRepository].
final class SupabaseInventoryRepository implements InventoryRepository {
  SupabaseInventoryRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<Result<Inventory>> createGrade({
    required String abacaType,
    String? description,
    double initialStockKg = 0.0,
    double minStockThresholdKg = 0.0,
    String? actorEmployeeId,
  }) async {
    final errors = <String, String>{};
    InputValidators.requireNonEmpty(errors, 'abacaType', abacaType);
    InputValidators.validateMaxLength(
      errors,
      'description',
      description,
      500,
    );
    InputValidators.requireNonNegative(
      errors,
      'initialStockKg',
      initialStockKg,
    );
    InputValidators.requireNonNegative(
      errors,
      'minStockThresholdKg',
      minStockThresholdKg,
    );
    final validation = InputValidators.toFailure(errors);
    if (validation != null) return Err<Inventory>(validation);

    try {
      final row = await _client
          .from(InventorySupabaseDto.tableName)
          .insert(
            InventorySupabaseDto.toInsertMap(
              abacaType: abacaType,
              description: description,
              initialStockKg: initialStockKg,
              minStockThresholdKg: minStockThresholdKg,
            ),
          )
          .select()
          .single();

      final created = InventorySupabaseDto.fromSupabase(row);
      await SupabaseAuditRepository.tryRecordAudit(
        _client,
        actorEmployeeId: actorEmployeeId,
        action: AuditAction.created,
        entityType: AuditEntityType.inventory,
        entityId: created.id,
        description: 'Created inventory grade ${created.abacaType}.',
        newValues: <String, Object?>{
          'abaca_type': created.abacaType,
          'current_stock_kg': created.currentStockKg,
          'min_stock_threshold_kg': created.minStockThresholdKg,
        },
      );
      return Ok<Inventory>(created);
    } catch (error) {
      return Err<Inventory>(
        SupabaseHelpers.mapError(error, entityName: 'Inventory'),
      );
    }
  }

  @override
  Future<Result<Inventory>> getInventoryById(String id) async {
    try {
      final row = await _client
          .from(InventorySupabaseDto.tableName)
          .select()
          .eq('inventory_id', id)
          .maybeSingle();

      if (row == null) {
        return Err<Inventory>(
          NotFoundFailure(
            entityName: 'Inventory',
            entityId: id,
            message: 'Inventory grade $id was not found.',
          ),
        );
      }
      return Ok<Inventory>(InventorySupabaseDto.fromSupabase(row));
    } catch (error) {
      return Err<Inventory>(
        SupabaseHelpers.mapError(error, entityName: 'Inventory', entityId: id),
      );
    }
  }

  @override
  Future<Result<Inventory>> getInventoryByAbacaType(String abacaType) async {
    final trimmed = abacaType.trim();
    if (trimmed.isEmpty) {
      return Err<Inventory>(
        ValidationFailure(
          message: 'Abaca type is required.',
          fieldErrors: const <String, String>{
            'abacaType': 'abacaType is required.',
          },
        ),
      );
    }

    try {
      final row = await _client
          .from(InventorySupabaseDto.tableName)
          .select()
          .ilike('abaca_type', trimmed)
          .maybeSingle();

      if (row == null) {
        return Err<Inventory>(
          NotFoundFailure(
            entityName: 'Inventory',
            entityId: trimmed,
            message: 'Inventory grade "$trimmed" was not found.',
          ),
        );
      }
      return Ok<Inventory>(InventorySupabaseDto.fromSupabase(row));
    } catch (error) {
      return Err<Inventory>(
        SupabaseHelpers.mapError(
          error,
          entityName: 'Inventory',
          entityId: trimmed,
        ),
      );
    }
  }

  @override
  Future<Result<List<Inventory>>> getAllInventory({
    bool? isActive,
    bool onlyLowStock = false,
  }) async {
    try {
      var query = _client.from(InventorySupabaseDto.tableName).select();
      if (isActive != null) {
        query = query.eq('is_active', isActive);
      }

      final rows = await query.order('abaca_type', ascending: true);
      var items = rows.map(InventorySupabaseDto.fromSupabase).toList();
      if (onlyLowStock) {
        items = items.where((item) => item.isLowStock).toList(growable: false);
      }
      return Ok<List<Inventory>>(items);
    } catch (error) {
      return Err<List<Inventory>>(
        SupabaseHelpers.mapError(error, entityName: 'Inventory'),
      );
    }
  }

  @override
  Stream<List<Inventory>> watchInventory({
    bool? isActive,
    bool onlyLowStock = false,
  }) {
    final base = _client
        .from(InventorySupabaseDto.tableName)
        .stream(primaryKey: const <String>['inventory_id']);

    final filtered =
        isActive != null ? base.eq('is_active', isActive) : base;

    return filtered.order('abaca_type', ascending: true).map((rows) {
      var items = rows.map(InventorySupabaseDto.fromSupabase);
      if (onlyLowStock) {
        items = items.where((item) => item.isLowStock);
      }
      return items.toList(growable: false);
    });
  }

  @override
  Future<Result<Inventory>> updateGradeMetadata({
    required String id,
    String? abacaType,
    String? description,
    bool clearDescription = false,
    double? minStockThresholdKg,
    bool? isActive,
    String? actorEmployeeId,
  }) async {
    final errors = <String, String>{};
    if (abacaType != null) {
      InputValidators.requireNonEmpty(errors, 'abacaType', abacaType);
    }
    InputValidators.validateMaxLength(
      errors,
      'description',
      description,
      500,
    );
    if (minStockThresholdKg != null) {
      InputValidators.requireNonNegative(
        errors,
        'minStockThresholdKg',
        minStockThresholdKg,
      );
    }
    final validation = InputValidators.toFailure(errors);
    if (validation != null) return Err<Inventory>(validation);

    final updates = <String, dynamic>{};
    if (abacaType != null) updates['abaca_type'] = abacaType.trim();
    if (clearDescription) {
      updates['description'] = null;
    } else if (description != null) {
      final trimmed = description.trim();
      updates['description'] = trimmed.isEmpty ? null : trimmed;
    }
    if (minStockThresholdKg != null) {
      updates['min_stock_threshold_kg'] =
          DecimalPrecision.round2(minStockThresholdKg);
    }
    if (isActive != null) {
      updates['is_active'] = isActive;
    }

    if (updates.isEmpty) {
      return getInventoryById(id);
    }

    try {
      // Composite FK (inventory_id, abaca_type) with ON UPDATE CASCADE
      // automatically propagates abaca_type renames onto orders.
      final row = await _client
          .from(InventorySupabaseDto.tableName)
          .update(updates)
          .eq('inventory_id', id)
          .select()
          .maybeSingle();

      if (row == null) {
        return Err<Inventory>(
          NotFoundFailure(
            entityName: 'Inventory',
            entityId: id,
            message: 'Inventory grade $id was not found.',
          ),
        );
      }

      final updated = InventorySupabaseDto.fromSupabase(row);
      await SupabaseAuditRepository.tryRecordAudit(
        _client,
        actorEmployeeId: actorEmployeeId,
        action: AuditAction.updated,
        entityType: AuditEntityType.inventory,
        entityId: updated.id,
        description: 'Updated inventory grade ${updated.abacaType}.',
        newValues: Map<String, Object?>.from(updates),
      );
      return Ok<Inventory>(updated);
    } catch (error) {
      return Err<Inventory>(
        SupabaseHelpers.mapError(error, entityName: 'Inventory', entityId: id),
      );
    }
  }

  @override
  Future<Result<void>> deleteGrade(
    String id, {
    String? actorEmployeeId,
  }) async {
    try {
      final existing = await getInventoryById(id);
      if (existing.isErr) return Err<void>(existing.failureOrNull!);

      // Postgres ON DELETE RESTRICT protects orders, stock_in_items, stock_outs.
      await _client
          .from(InventorySupabaseDto.tableName)
          .delete()
          .eq('inventory_id', id);

      await SupabaseAuditRepository.tryRecordAudit(
        _client,
        actorEmployeeId: actorEmployeeId,
        action: AuditAction.deleted,
        entityType: AuditEntityType.inventory,
        entityId: id,
        description:
            'Deleted inventory grade ${existing.valueOrNull?.abacaType ?? id}.',
      );
      return const Ok<void>(null);
    } catch (error) {
      return Err<void>(
        SupabaseHelpers.mapError(error, entityName: 'Inventory', entityId: id),
      );
    }
  }
}
