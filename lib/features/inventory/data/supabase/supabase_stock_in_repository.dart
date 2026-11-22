import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/data/input_validators.dart';
import '../../../../core/data/supabase/supabase_helpers.dart';
import '../../../../core/errors/app_failure.dart';
import '../../../../core/result/result.dart';
import '../../../../core/types/query_filters.dart';
import '../../domain/entities/stock_in.dart';
import '../../domain/entities/stock_in_item.dart';
import '../../domain/repositories/stock_in_repository.dart';
import 'stock_in_supabase_dto.dart';

/// PostgreSQL / Supabase implementation of [StockInRepository].
///
/// Uses atomic Postgres RPCs (`rpc_create_stock_in`, `rpc_delete_stock_in`)
/// with row-level `FOR UPDATE` locking on `inventory`.
final class SupabaseStockInRepository implements StockInRepository {
  SupabaseStockInRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<Result<StockInWithDetails>> createStockIn({
    String? orderId,
    required String supplierId,
    required String employeeId,
    required DateTime dateReceived,
    String? notes,
    required List<NewStockInItemInput> items,
  }) async {
    final errors = <String, String>{};
    InputValidators.requireNonEmpty(errors, 'supplierId', supplierId);
    InputValidators.requireNonEmpty(errors, 'employeeId', employeeId);
    if (items.isEmpty) {
      errors['items'] = 'At least one stock-in item is required.';
    } else {
      for (var i = 0; i < items.length; i++) {
        InputValidators.requireNonEmpty(
          errors,
          'items[$i].inventoryId',
          items[i].inventoryId,
        );
        InputValidators.requirePositive(
          errors,
          'items[$i].quantityKg',
          items[i].quantityKg,
        );
        InputValidators.requireNonNegative(
          errors,
          'items[$i].costPerKg',
          items[i].costPerKg,
        );
      }
    }
    final validation = InputValidators.toFailure(errors);
    if (validation != null) return Err<StockInWithDetails>(validation);

    try {
      final stockInId = await _client.rpc<String>(
        'rpc_create_stock_in',
        params: <String, dynamic>{
          'p_order_id': orderId,
          'p_supplier_id': supplierId,
          'p_employee_id': employeeId,
          'p_date_received': SupabaseHelpers.formatDateOnly(dateReceived),
          'p_notes': notes?.trim().isEmpty == true ? null : notes?.trim(),
          'p_items': StockInSupabaseDto.itemsToRpcJson(items),
        },
      );

      return await getStockInWithItems(stockInId);
    } catch (error) {
      return Err<StockInWithDetails>(
        SupabaseHelpers.mapError(error, entityName: 'StockIn'),
      );
    }
  }

  @override
  Future<Result<StockInWithDetails>> getStockInWithItems(String id) async {
    try {
      final row = await _client
          .from(StockInSupabaseDto.tableName)
          .select(StockInSupabaseDto.joinedSelect)
          .eq('stockin_id', id)
          .maybeSingle();

      if (row == null) {
        return Err<StockInWithDetails>(
          NotFoundFailure(
            entityName: 'StockIn',
            entityId: id,
            message: 'Stock-in receipt $id was not found.',
          ),
        );
      }
      return Ok<StockInWithDetails>(
        StockInSupabaseDto.detailsFromSupabase(row),
      );
    } catch (error) {
      return Err<StockInWithDetails>(
        SupabaseHelpers.mapError(error, entityName: 'StockIn', entityId: id),
      );
    }
  }

  @override
  Future<Result<List<StockInWithDetails>>> getStockIns({
    String? supplierId,
    String? orderId,
    String? inventoryId,
    DateRangeFilter? dateRange,
  }) async {
    final rangeFailure = InputValidators.validateDateRange(dateRange);
    if (rangeFailure != null) return Err<List<StockInWithDetails>>(rangeFailure);

    try {
      List<String>? matchingStockInIds;
      if (inventoryId != null) {
        final itemRows = await _client
            .from(StockInSupabaseDto.itemsTableName)
            .select('stockin_id')
            .eq('inventory_id', inventoryId);
        matchingStockInIds = itemRows
            .map((row) => row['stockin_id'] as String)
            .toSet()
            .toList(growable: false);
        if (matchingStockInIds.isEmpty) {
          return const Ok<List<StockInWithDetails>>(<StockInWithDetails>[]);
        }
      }

      var query = _client
          .from(StockInSupabaseDto.tableName)
          .select(StockInSupabaseDto.joinedSelect);

      if (supplierId != null) {
        query = query.eq('supplier_id', supplierId);
      }
      if (orderId != null) {
        query = query.eq('order_id', orderId);
      }
      if (matchingStockInIds != null) {
        query = query.inFilter('stockin_id', matchingStockInIds);
      }
      if (dateRange?.startDate != null) {
        query = query.gte(
          'date_received',
          SupabaseHelpers.formatDateOnly(dateRange!.startDate!),
        );
      }
      if (dateRange?.endDate != null) {
        query = query.lte(
          'date_received',
          SupabaseHelpers.formatDateOnly(dateRange!.endDate!),
        );
      }

      final rows = await query
          .order('date_received', ascending: false)
          .order('created_at', ascending: false);

      return Ok<List<StockInWithDetails>>(
        rows
            .map(StockInSupabaseDto.detailsFromSupabase)
            .toList(growable: false),
      );
    } catch (error) {
      return Err<List<StockInWithDetails>>(
        SupabaseHelpers.mapError(error, entityName: 'StockIn'),
      );
    }
  }

  @override
  Stream<List<StockInWithDetails>> watchStockIns({
    String? supplierId,
    String? orderId,
  }) {
    final base = _client
        .from(StockInSupabaseDto.tableName)
        .stream(primaryKey: const <String>['stockin_id']);

    final filtered = supplierId != null
        ? base.eq('supplier_id', supplierId)
        : (orderId != null ? base.eq('order_id', orderId) : base);

    return filtered
        .order('date_received', ascending: false)
        .asyncMap((rows) async {
      var headers = rows;
      if (supplierId != null && orderId != null) {
        headers = headers
            .where((row) => row['order_id'] == orderId)
            .toList(growable: false);
      }
      if (headers.isEmpty) return const <StockInWithDetails>[];

      final ids = headers
          .map((row) => row['stockin_id'] as String)
          .toList(growable: false);
      final joined = await _client
          .from(StockInSupabaseDto.tableName)
          .select(StockInSupabaseDto.joinedSelect)
          .inFilter('stockin_id', ids)
          .order('date_received', ascending: false)
          .order('created_at', ascending: false);

      return joined
          .map(StockInSupabaseDto.detailsFromSupabase)
          .toList(growable: false);
    });
  }

  @override
  Future<Result<void>> deleteStockIn(
    String id, {
    String? actorEmployeeId,
  }) async {
    try {
      await _client.rpc<void>(
        'rpc_delete_stock_in',
        params: <String, dynamic>{
          'p_stockin_id': id,
          'p_actor_employee_id': actorEmployeeId,
        },
      );
      return const Ok<void>(null);
    } catch (error) {
      return Err<void>(
        SupabaseHelpers.mapError(error, entityName: 'StockIn', entityId: id),
      );
    }
  }
}
