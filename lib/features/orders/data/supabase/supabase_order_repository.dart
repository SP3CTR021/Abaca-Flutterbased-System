import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/data/input_validators.dart';
import '../../../../core/data/supabase/supabase_helpers.dart';
import '../../../../core/errors/app_failure.dart';
import '../../../../core/result/result.dart';
import '../../../../core/types/query_filters.dart';
import '../../../../core/utils/decimal_precision.dart';
import '../../../audit/data/supabase/supabase_audit_repository.dart';
import '../../../audit/domain/entities/audit_enums.dart';
import '../../../inventory/data/supabase/inventory_supabase_dto.dart';
import '../../domain/entities/order.dart';
import '../../domain/entities/order_status.dart';
import '../../domain/repositories/order_repository.dart';
import 'order_supabase_dto.dart';

/// PostgreSQL / Supabase implementation of [OrderRepository].
final class SupabaseOrderRepository implements OrderRepository {
  SupabaseOrderRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<Result<Order>> createOrder({
    required String customerId,
    required String employeeId,
    required String inventoryId,
    required DateTime orderDate,
    required double quantityKg,
    required double pricePerKg,
    String? notes,
  }) async {
    final errors = <String, String>{};
    InputValidators.requireNonEmpty(errors, 'customerId', customerId);
    InputValidators.requireNonEmpty(errors, 'employeeId', employeeId);
    InputValidators.requireNonEmpty(errors, 'inventoryId', inventoryId);
    InputValidators.requirePositive(errors, 'quantityKg', quantityKg);
    InputValidators.requireNonNegative(errors, 'pricePerKg', pricePerKg);
    final validation = InputValidators.toFailure(errors);
    if (validation != null) return Err<Order>(validation);

    try {
      // Authoritatively resolve abaca_type from inventory so snapshot matches
      // the composite FK (inventory_id, abaca_type).
      final invRow = await _client
          .from(InventorySupabaseDto.tableName)
          .select('inventory_id, abaca_type')
          .eq('inventory_id', inventoryId)
          .maybeSingle();

      if (invRow == null) {
        return Err<Order>(
          NotFoundFailure(
            entityName: 'Inventory',
            entityId: inventoryId,
            message: 'Inventory grade $inventoryId was not found.',
          ),
        );
      }

      final abacaType = invRow['abaca_type'] as String;
      final totalAmount = DecimalPrecision.multiply2(quantityKg, pricePerKg);

      final row = await _client
          .from(OrderSupabaseDto.tableName)
          .insert(
            OrderSupabaseDto.toInsertMap(
              customerId: customerId,
              employeeId: employeeId,
              inventoryId: inventoryId,
              abacaType: abacaType,
              orderDate: orderDate,
              quantityKg: quantityKg,
              pricePerKg: pricePerKg,
              totalAmount: totalAmount,
              notes: notes,
            ),
          )
          .select()
          .single();

      final created = OrderSupabaseDto.fromSupabase(row);
      await SupabaseAuditRepository.tryRecordAudit(
        _client,
        actorEmployeeId: employeeId,
        action: AuditAction.created,
        entityType: AuditEntityType.order,
        entityId: created.id,
        description:
            'Created order for ${created.quantityKg} kg of ${created.abacaType}.',
        newValues: <String, Object?>{
          'customer_id': created.customerId,
          'inventory_id': created.inventoryId,
          'quantity_kg': created.quantityKg,
          'total_amount': created.totalAmount,
        },
      );
      return Ok<Order>(created);
    } catch (error) {
      return Err<Order>(
        SupabaseHelpers.mapError(error, entityName: 'Order'),
      );
    }
  }

  @override
  Future<Result<Order>> getOrderById(String id) async {
    try {
      final row = await _client
          .from(OrderSupabaseDto.tableName)
          .select()
          .eq('order_id', id)
          .maybeSingle();

      if (row == null) {
        return Err<Order>(
          NotFoundFailure(
            entityName: 'Order',
            entityId: id,
            message: 'Order $id was not found.',
          ),
        );
      }
      return Ok<Order>(OrderSupabaseDto.fromSupabase(row));
    } catch (error) {
      return Err<Order>(
        SupabaseHelpers.mapError(error, entityName: 'Order', entityId: id),
      );
    }
  }

  @override
  Future<Result<OrderWithDetails>> getOrderWithDetails(String id) async {
    try {
      final row = await _client
          .from(OrderSupabaseDto.tableName)
          .select(OrderSupabaseDto.joinedSelect)
          .eq('order_id', id)
          .maybeSingle();

      if (row == null) {
        return Err<OrderWithDetails>(
          NotFoundFailure(
            entityName: 'Order',
            entityId: id,
            message: 'Order $id was not found.',
          ),
        );
      }
      return Ok<OrderWithDetails>(OrderSupabaseDto.detailsFromSupabase(row));
    } catch (error) {
      return Err<OrderWithDetails>(
        SupabaseHelpers.mapError(error, entityName: 'Order', entityId: id),
      );
    }
  }

  @override
  Future<Result<List<Order>>> getOrders({
    String? customerId,
    String? employeeId,
    String? inventoryId,
    OrderStatus? status,
    DateRangeFilter? dateRange,
  }) async {
    final rangeFailure = InputValidators.validateDateRange(dateRange);
    if (rangeFailure != null) return Err<List<Order>>(rangeFailure);

    try {
      var query = _client.from(OrderSupabaseDto.tableName).select();
      if (customerId != null) {
        query = query.eq('customer_id', customerId);
      }
      if (employeeId != null) {
        query = query.eq('employee_id', employeeId);
      }
      if (inventoryId != null) {
        query = query.eq('inventory_id', inventoryId);
      }
      if (status != null) {
        query = query.eq('status', status.dbValue);
      }
      if (dateRange?.startDate != null) {
        query = query.gte(
          'order_date',
          SupabaseHelpers.formatDateOnly(dateRange!.startDate!),
        );
      }
      if (dateRange?.endDate != null) {
        query = query.lte(
          'order_date',
          SupabaseHelpers.formatDateOnly(dateRange!.endDate!),
        );
      }

      final rows = await query
          .order('order_date', ascending: false)
          .order('created_at', ascending: false);

      return Ok<List<Order>>(
        rows.map(OrderSupabaseDto.fromSupabase).toList(growable: false),
      );
    } catch (error) {
      return Err<List<Order>>(
        SupabaseHelpers.mapError(error, entityName: 'Order'),
      );
    }
  }

  @override
  Stream<List<Order>> watchOrders({
    String? customerId,
    OrderStatus? status,
  }) {
    final base = _client
        .from(OrderSupabaseDto.tableName)
        .stream(primaryKey: const <String>['order_id']);

    final filtered = customerId != null
        ? base.eq('customer_id', customerId)
        : (status != null ? base.eq('status', status.dbValue) : base);

    return filtered.order('order_date', ascending: false).map((rows) {
      var orders = rows.map(OrderSupabaseDto.fromSupabase);
      if (customerId != null && status != null) {
        orders = orders.where((order) => order.status == status);
      }
      return orders.toList(growable: false);
    });
  }

  @override
  Future<Result<Order>> markOrderStocked({
    required String orderId,
    required String actorEmployeeId,
  }) async {
    try {
      final row = await _client.rpc<Map<String, dynamic>>(
        'rpc_mark_order_stocked',
        params: <String, dynamic>{
          'p_order_id': orderId,
          'p_actor_employee_id': actorEmployeeId,
        },
      );
      return Ok<Order>(OrderSupabaseDto.fromSupabase(row));
    } catch (error) {
      return Err<Order>(
        SupabaseHelpers.mapError(error, entityName: 'Order', entityId: orderId),
      );
    }
  }

  @override
  Future<Result<Order>> cancelOrder({
    required String orderId,
    required String actorEmployeeId,
    String? reason,
  }) async {
    try {
      final row = await _client.rpc<Map<String, dynamic>>(
        'rpc_cancel_order',
        params: <String, dynamic>{
          'p_order_id': orderId,
          'p_actor_employee_id': actorEmployeeId,
          'p_reason': reason,
        },
      );
      return Ok<Order>(OrderSupabaseDto.fromSupabase(row));
    } catch (error) {
      return Err<Order>(
        SupabaseHelpers.mapError(error, entityName: 'Order', entityId: orderId),
      );
    }
  }

  @override
  Future<Result<Order>> updatePendingOrder({
    required String orderId,
    String? inventoryId,
    double? quantityKg,
    double? pricePerKg,
    DateTime? orderDate,
    String? notes,
    bool clearNotes = false,
    required String actorEmployeeId,
  }) async {
    final errors = <String, String>{};
    if (quantityKg != null) {
      InputValidators.requirePositive(errors, 'quantityKg', quantityKg);
    }
    if (pricePerKg != null) {
      InputValidators.requireNonNegative(errors, 'pricePerKg', pricePerKg);
    }
    final validation = InputValidators.toFailure(errors);
    if (validation != null) return Err<Order>(validation);

    try {
      final currentResult = await getOrderById(orderId);
      if (currentResult.isErr) return currentResult;
      final current = currentResult.valueOrNull!;

      if (current.status != OrderStatus.pending) {
        return Err<Order>(
          InvalidStateTransitionFailure(
            entityName: 'Order',
            currentState: current.status.dbValue,
            attemptedAction: 'update_pending_order',
            message: 'Only pending orders can be edited.',
          ),
        );
      }

      var targetInventoryId = current.inventoryId;
      var targetAbacaType = current.abacaType;
      if (inventoryId != null && inventoryId != current.inventoryId) {
        final invRow = await _client
            .from(InventorySupabaseDto.tableName)
            .select('inventory_id, abaca_type')
            .eq('inventory_id', inventoryId)
            .maybeSingle();
        if (invRow == null) {
          return Err<Order>(
            NotFoundFailure(
              entityName: 'Inventory',
              entityId: inventoryId,
              message: 'Inventory grade $inventoryId was not found.',
            ),
          );
        }
        targetInventoryId = invRow['inventory_id'] as String;
        targetAbacaType = invRow['abaca_type'] as String;
      }

      final nextQty = quantityKg ?? current.quantityKg;
      final nextPrice = pricePerKg ?? current.pricePerKg;
      final nextTotal = DecimalPrecision.multiply2(nextQty, nextPrice);

      final updates = <String, dynamic>{
        'inventory_id': targetInventoryId,
        'abaca_type': targetAbacaType,
        'quantity_kg': DecimalPrecision.round2(nextQty),
        'price_per_kg': DecimalPrecision.round2(nextPrice),
        'total_amount': nextTotal,
        if (orderDate != null)
          'order_date': SupabaseHelpers.formatDateOnly(orderDate),
        if (clearNotes)
          'notes': null
        else if (notes != null)
          'notes': notes.trim().isEmpty ? null : notes.trim(),
      };

      final row = await _client
          .from(OrderSupabaseDto.tableName)
          .update(updates)
          .eq('order_id', orderId)
          .select()
          .single();

      final updated = OrderSupabaseDto.fromSupabase(row);
      await SupabaseAuditRepository.tryRecordAudit(
        _client,
        actorEmployeeId: actorEmployeeId,
        action: AuditAction.updated,
        entityType: AuditEntityType.order,
        entityId: orderId,
        description: 'Updated pending order $orderId.',
      );
      return Ok<Order>(updated);
    } catch (error) {
      return Err<Order>(
        SupabaseHelpers.mapError(error, entityName: 'Order', entityId: orderId),
      );
    }
  }

  @override
  Future<Result<void>> deleteOrder(
    String id, {
    String? actorEmployeeId,
  }) async {
    try {
      final existing = await getOrderById(id);
      if (existing.isErr) return Err<void>(existing.failureOrNull!);

      // Postgres ON DELETE RESTRICT on payments & deliveries prevents deleting
      // orders with financial or dispatch records (23503 -> ConflictFailure).
      // Linked stock_ins.order_id values are automatically nullified (SET NULL).
      await _client
          .from(OrderSupabaseDto.tableName)
          .delete()
          .eq('order_id', id);

      await SupabaseAuditRepository.tryRecordAudit(
        _client,
        actorEmployeeId: actorEmployeeId,
        action: AuditAction.deleted,
        entityType: AuditEntityType.order,
        entityId: id,
        description: 'Deleted order $id.',
      );
      return const Ok<void>(null);
    } catch (error) {
      return Err<void>(
        SupabaseHelpers.mapError(error, entityName: 'Order', entityId: id),
      );
    }
  }
}
