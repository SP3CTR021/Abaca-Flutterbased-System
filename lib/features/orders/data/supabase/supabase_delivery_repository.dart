import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/data/input_validators.dart';
import '../../../../core/data/supabase/supabase_helpers.dart';
import '../../../../core/errors/app_failure.dart';
import '../../../../core/result/result.dart';
import '../../../../core/types/query_filters.dart';
import '../../../audit/data/supabase/supabase_audit_repository.dart';
import '../../../audit/domain/entities/audit_enums.dart';
import '../../domain/entities/delivery.dart';
import '../../domain/entities/delivery_status.dart';
import '../../domain/entities/order_status.dart';
import '../../domain/repositories/delivery_repository.dart';
import 'delivery_supabase_dto.dart';
import 'order_supabase_dto.dart';

/// PostgreSQL / Supabase implementation of [DeliveryRepository].
final class SupabaseDeliveryRepository implements DeliveryRepository {
  SupabaseDeliveryRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<Result<Delivery>> scheduleDelivery({
    required String orderId,
    required String employeeId,
    required DateTime deliveryDate,
    String? notes,
    String? actorEmployeeId,
  }) async {
    final errors = <String, String>{};
    InputValidators.requireNonEmpty(errors, 'orderId', orderId);
    InputValidators.requireNonEmpty(errors, 'employeeId', employeeId);
    final validation = InputValidators.toFailure(errors);
    if (validation != null) return Err<Delivery>(validation);

    try {
      final orderRow = await _client
          .from(OrderSupabaseDto.tableName)
          .select('order_id, status')
          .eq('order_id', orderId)
          .maybeSingle();

      if (orderRow == null) {
        return Err<Delivery>(
          NotFoundFailure(
            entityName: 'Order',
            entityId: orderId,
            message: 'Order $orderId was not found.',
          ),
        );
      }

      final orderStatus = OrderStatus.fromDb(orderRow['status'] as String);
      if (orderStatus != OrderStatus.stocked) {
        return Err<Delivery>(
          InvalidStateTransitionFailure(
            entityName: 'Order',
            currentState: orderStatus.dbValue,
            attemptedAction: 'schedule_delivery',
            message:
                'Deliveries can only be scheduled for stocked orders.',
          ),
        );
      }

      // UNIQUE(order_id) enforces strict 1:1 per order (23505 -> ConflictFailure).
      final row = await _client
          .from(DeliverySupabaseDto.tableName)
          .insert(
            DeliverySupabaseDto.toInsertMap(
              orderId: orderId,
              employeeId: employeeId,
              deliveryDate: deliveryDate,
              notes: notes,
            ),
          )
          .select()
          .single();

      final created = DeliverySupabaseDto.fromSupabase(row);
      await SupabaseAuditRepository.tryRecordAudit(
        _client,
        actorEmployeeId: actorEmployeeId ?? employeeId,
        action: AuditAction.created,
        entityType: AuditEntityType.delivery,
        entityId: created.id,
        description: 'Scheduled delivery for order $orderId.',
      );
      return Ok<Delivery>(created);
    } catch (error) {
      return Err<Delivery>(
        SupabaseHelpers.mapError(error, entityName: 'Delivery'),
      );
    }
  }

  @override
  Future<Result<Delivery>> completeDelivery({
    required String deliveryId,
    required String actorEmployeeId,
    DateTime? deliveredAt,
    String? notes,
  }) async {
    try {
      final row = await _client.rpc<Map<String, dynamic>>(
        'rpc_complete_delivery',
        params: <String, dynamic>{
          'p_delivery_id': deliveryId,
          'p_actor_employee_id': actorEmployeeId,
          'p_delivered_at': deliveredAt?.toUtc().toIso8601String(),
          'p_notes': notes?.trim().isEmpty == true ? null : notes?.trim(),
        },
      );
      return Ok<Delivery>(DeliverySupabaseDto.fromSupabase(row));
    } catch (error) {
      return Err<Delivery>(
        SupabaseHelpers.mapError(
          error,
          entityName: 'Delivery',
          entityId: deliveryId,
        ),
      );
    }
  }

  @override
  Future<Result<Delivery>> getDeliveryById(String id) async {
    try {
      final row = await _client
          .from(DeliverySupabaseDto.tableName)
          .select()
          .eq('delivery_id', id)
          .maybeSingle();

      if (row == null) {
        return Err<Delivery>(
          NotFoundFailure(
            entityName: 'Delivery',
            entityId: id,
            message: 'Delivery $id was not found.',
          ),
        );
      }
      return Ok<Delivery>(DeliverySupabaseDto.fromSupabase(row));
    } catch (error) {
      return Err<Delivery>(
        SupabaseHelpers.mapError(error, entityName: 'Delivery', entityId: id),
      );
    }
  }

  @override
  Future<Result<Delivery?>> getDeliveryByOrderId(String orderId) async {
    try {
      final row = await _client
          .from(DeliverySupabaseDto.tableName)
          .select()
          .eq('order_id', orderId)
          .maybeSingle();

      return Ok<Delivery?>(
        row == null ? null : DeliverySupabaseDto.fromSupabase(row),
      );
    } catch (error) {
      return Err<Delivery?>(
        SupabaseHelpers.mapError(error, entityName: 'Delivery'),
      );
    }
  }

  @override
  Future<Result<List<Delivery>>> getDeliveries({
    String? employeeId,
    DeliveryStatus? status,
    DateRangeFilter? dateRange,
  }) async {
    final rangeFailure = InputValidators.validateDateRange(dateRange);
    if (rangeFailure != null) return Err<List<Delivery>>(rangeFailure);

    try {
      var query = _client.from(DeliverySupabaseDto.tableName).select();
      if (employeeId != null) {
        query = query.eq('employee_id', employeeId);
      }
      if (status != null) {
        query = query.eq('status', status.dbValue);
      }
      if (dateRange?.startDate != null) {
        query = query.gte(
          'delivery_date',
          SupabaseHelpers.formatDateOnly(dateRange!.startDate!),
        );
      }
      if (dateRange?.endDate != null) {
        query = query.lte(
          'delivery_date',
          SupabaseHelpers.formatDateOnly(dateRange!.endDate!),
        );
      }

      final rows = await query
          .order('delivery_date', ascending: false)
          .order('created_at', ascending: false);

      return Ok<List<Delivery>>(
        rows.map(DeliverySupabaseDto.fromSupabase).toList(growable: false),
      );
    } catch (error) {
      return Err<List<Delivery>>(
        SupabaseHelpers.mapError(error, entityName: 'Delivery'),
      );
    }
  }

  @override
  Stream<List<Delivery>> watchDeliveries({
    String? employeeId,
    DeliveryStatus? status,
  }) {
    final base = _client
        .from(DeliverySupabaseDto.tableName)
        .stream(primaryKey: const <String>['delivery_id']);

    final filtered = employeeId != null
        ? base.eq('employee_id', employeeId)
        : (status != null ? base.eq('status', status.dbValue) : base);

    return filtered.order('delivery_date', ascending: true).map((rows) {
      var items = rows.map(DeliverySupabaseDto.fromSupabase);
      if (employeeId != null && status != null) {
        items = items.where((delivery) => delivery.status == status);
      }
      return items.toList(growable: false);
    });
  }

  @override
  Future<Result<Delivery>> reassignDelivery({
    required String deliveryId,
    required String newEmployeeId,
    DateTime? newDeliveryDate,
    String? notes,
    required String actorEmployeeId,
  }) async {
    final errors = <String, String>{};
    InputValidators.requireNonEmpty(errors, 'newEmployeeId', newEmployeeId);
    final validation = InputValidators.toFailure(errors);
    if (validation != null) return Err<Delivery>(validation);

    try {
      final currentResult = await getDeliveryById(deliveryId);
      if (currentResult.isErr) return currentResult;
      final current = currentResult.valueOrNull!;

      if (current.status != DeliveryStatus.pending) {
        return Err<Delivery>(
          InvalidStateTransitionFailure(
            entityName: 'Delivery',
            currentState: current.status.dbValue,
            attemptedAction: 'reassign_delivery',
            message: 'Completed deliveries cannot be reassigned.',
          ),
        );
      }

      final updates = <String, dynamic>{
        'employee_id': newEmployeeId,
        if (newDeliveryDate != null)
          'delivery_date': SupabaseHelpers.formatDateOnly(newDeliveryDate),
        if (notes != null)
          'notes': notes.trim().isEmpty ? null : notes.trim(),
      };

      final row = await _client
          .from(DeliverySupabaseDto.tableName)
          .update(updates)
          .eq('delivery_id', deliveryId)
          .select()
          .single();

      final updated = DeliverySupabaseDto.fromSupabase(row);
      await SupabaseAuditRepository.tryRecordAudit(
        _client,
        actorEmployeeId: actorEmployeeId,
        action: AuditAction.updated,
        entityType: AuditEntityType.delivery,
        entityId: deliveryId,
        description: 'Reassigned delivery $deliveryId to $newEmployeeId.',
      );
      return Ok<Delivery>(updated);
    } catch (error) {
      return Err<Delivery>(
        SupabaseHelpers.mapError(
          error,
          entityName: 'Delivery',
          entityId: deliveryId,
        ),
      );
    }
  }
}
