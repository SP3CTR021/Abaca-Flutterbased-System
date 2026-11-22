import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/data/input_validators.dart';
import '../../../../core/data/supabase/supabase_helpers.dart';
import '../../../../core/errors/app_failure.dart';
import '../../../../core/result/result.dart';
import '../../../../core/types/query_filters.dart';
import '../../domain/entities/stock_out.dart';
import '../../domain/entities/stock_out_reason.dart';
import '../../domain/repositories/stock_out_repository.dart';
import 'stock_out_supabase_dto.dart';

/// PostgreSQL / Supabase implementation of [StockOutRepository].
final class SupabaseStockOutRepository implements StockOutRepository {
  SupabaseStockOutRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<Result<StockOut>> createStockOut({
    required String inventoryId,
    required String employeeId,
    required double quantityKg,
    required StockOutReason reason,
    String? notes,
    required DateTime date,
  }) async {
    if (reason == StockOutReason.released) {
      return const Err<StockOut>(
        InvalidStateTransitionFailure(
          entityName: 'StockOut',
          currentState: 'manual',
          attemptedAction: 'create_released_stock_out',
          message:
              'Released stock-outs must be created via DeliveryRepository.completeDelivery.',
        ),
      );
    }

    final errors = <String, String>{};
    InputValidators.requireNonEmpty(errors, 'inventoryId', inventoryId);
    InputValidators.requireNonEmpty(errors, 'employeeId', employeeId);
    InputValidators.requirePositive(errors, 'quantityKg', quantityKg);
    final validation = InputValidators.toFailure(errors);
    if (validation != null) return Err<StockOut>(validation);

    try {
      final row = await _client.rpc<Map<String, dynamic>>(
        'rpc_create_stock_out',
        params: <String, dynamic>{
          'p_inventory_id': inventoryId,
          'p_employee_id': employeeId,
          'p_quantity_kg': quantityKg,
          'p_reason': reason.dbValue,
          'p_notes': notes?.trim().isEmpty == true ? null : notes?.trim(),
          'p_date': SupabaseHelpers.formatDateOnly(date),
        },
      );
      return Ok<StockOut>(StockOutSupabaseDto.fromSupabase(row));
    } catch (error) {
      return Err<StockOut>(
        SupabaseHelpers.mapError(error, entityName: 'StockOut'),
      );
    }
  }

  @override
  Future<Result<StockOut>> getStockOutById(String id) async {
    try {
      final row = await _client
          .from(StockOutSupabaseDto.tableName)
          .select()
          .eq('stockout_id', id)
          .maybeSingle();

      if (row == null) {
        return Err<StockOut>(
          NotFoundFailure(
            entityName: 'StockOut',
            entityId: id,
            message: 'StockOut $id was not found.',
          ),
        );
      }
      return Ok<StockOut>(StockOutSupabaseDto.fromSupabase(row));
    } catch (error) {
      return Err<StockOut>(
        SupabaseHelpers.mapError(error, entityName: 'StockOut', entityId: id),
      );
    }
  }

  @override
  Future<Result<List<StockOut>>> getStockOuts({
    String? inventoryId,
    StockOutReason? reason,
    String? orderId,
    DateRangeFilter? dateRange,
  }) async {
    final rangeFailure = InputValidators.validateDateRange(dateRange);
    if (rangeFailure != null) return Err<List<StockOut>>(rangeFailure);

    try {
      var query = _client.from(StockOutSupabaseDto.tableName).select();
      if (inventoryId != null) {
        query = query.eq('inventory_id', inventoryId);
      }
      if (reason != null) {
        query = query.eq('reason', reason.dbValue);
      }
      if (orderId != null) {
        query = query.eq('order_id', orderId);
      }
      if (dateRange?.startDate != null) {
        query = query.gte(
          'date',
          SupabaseHelpers.formatDateOnly(dateRange!.startDate!),
        );
      }
      if (dateRange?.endDate != null) {
        query = query.lte(
          'date',
          SupabaseHelpers.formatDateOnly(dateRange!.endDate!),
        );
      }

      final rows = await query
          .order('date', ascending: false)
          .order('created_at', ascending: false);

      return Ok<List<StockOut>>(
        rows.map(StockOutSupabaseDto.fromSupabase).toList(growable: false),
      );
    } catch (error) {
      return Err<List<StockOut>>(
        SupabaseHelpers.mapError(error, entityName: 'StockOut'),
      );
    }
  }

  @override
  Stream<List<StockOut>> watchStockOuts({
    String? inventoryId,
    StockOutReason? reason,
  }) {
    final base = _client
        .from(StockOutSupabaseDto.tableName)
        .stream(primaryKey: const <String>['stockout_id']);

    final filtered = inventoryId != null
        ? base.eq('inventory_id', inventoryId)
        : (reason != null ? base.eq('reason', reason.dbValue) : base);

    return filtered.order('date', ascending: false).map((rows) {
      var items = rows.map(StockOutSupabaseDto.fromSupabase);
      if (inventoryId != null && reason != null) {
        items = items.where((entry) => entry.reason == reason);
      }
      return items.toList(growable: false);
    });
  }

  @override
  Future<Result<void>> deleteStockOut(
    String id, {
    String? actorEmployeeId,
  }) async {
    try {
      await _client.rpc<void>(
        'rpc_delete_stock_out',
        params: <String, dynamic>{
          'p_stockout_id': id,
          'p_actor_employee_id': actorEmployeeId,
        },
      );
      return const Ok<void>(null);
    } catch (error) {
      return Err<void>(
        SupabaseHelpers.mapError(error, entityName: 'StockOut', entityId: id),
      );
    }
  }
}
