import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/data/input_validators.dart';
import '../../../../core/data/supabase/supabase_helpers.dart';
import '../../../../core/errors/app_failure.dart';
import '../../../../core/result/result.dart';
import '../../../../core/types/query_filters.dart';
import '../../../../core/utils/decimal_precision.dart';
import '../../domain/entities/payment.dart';
import '../../domain/repositories/payment_repository.dart';
import 'payment_supabase_dto.dart';

/// PostgreSQL / Supabase implementation of [PaymentRepository].
final class SupabasePaymentRepository implements PaymentRepository {
  SupabasePaymentRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<Result<Payment>> recordPayment({
    required String orderId,
    required String employeeId,
    required double amountPaid,
    required DateTime paymentDate,
    required String paymentMethod,
    String? referenceNumber,
    String? notes,
  }) async {
    final errors = <String, String>{};
    InputValidators.requireNonEmpty(errors, 'orderId', orderId);
    InputValidators.requireNonEmpty(errors, 'employeeId', employeeId);
    InputValidators.requirePositive(errors, 'amountPaid', amountPaid);
    InputValidators.requireNonEmpty(errors, 'paymentMethod', paymentMethod);
    InputValidators.validateMaxLength(errors, 'notes', notes, 2000);
    final validation = InputValidators.toFailure(errors);
    if (validation != null) return Err<Payment>(validation);

    try {
      final row = await _client.rpc<Map<String, dynamic>>(
        'rpc_record_payment',
        params: <String, dynamic>{
          'p_order_id': orderId,
          'p_employee_id': employeeId,
          'p_amount_paid': DecimalPrecision.round2(amountPaid),
          'p_payment_date': SupabaseHelpers.formatDateOnly(paymentDate),
          'p_payment_method': paymentMethod.trim(),
          'p_reference_number': referenceNumber?.trim().isEmpty == true
              ? null
              : referenceNumber?.trim(),
          'p_notes': notes?.trim().isEmpty == true ? null : notes?.trim(),
        },
      );
      return Ok<Payment>(PaymentSupabaseDto.fromSupabase(row));
    } catch (error) {
      return Err<Payment>(
        SupabaseHelpers.mapError(error, entityName: 'Payment'),
      );
    }
  }

  @override
  Future<Result<Payment>> getPaymentById(
    String id, {
    String? orderId,
  }) async {
    try {
      var query = _client
          .from(PaymentSupabaseDto.tableName)
          .select()
          .eq('payment_id', id);

      if (orderId != null) {
        query = query.eq('order_id', orderId);
      }

      final row = await query.maybeSingle();
      if (row == null) {
        return Err<Payment>(
          NotFoundFailure(
            entityName: 'Payment',
            entityId: id,
            message: 'Payment $id was not found.',
          ),
        );
      }
      return Ok<Payment>(PaymentSupabaseDto.fromSupabase(row));
    } catch (error) {
      return Err<Payment>(
        SupabaseHelpers.mapError(error, entityName: 'Payment', entityId: id),
      );
    }
  }

  @override
  Future<Result<List<Payment>>> getPaymentsForOrder(String orderId) async {
    try {
      final rows = await _client
          .from(PaymentSupabaseDto.tableName)
          .select()
          .eq('order_id', orderId)
          .order('payment_date', ascending: false)
          .order('created_at', ascending: false);

      return Ok<List<Payment>>(
        rows.map(PaymentSupabaseDto.fromSupabase).toList(growable: false),
      );
    } catch (error) {
      return Err<List<Payment>>(
        SupabaseHelpers.mapError(error, entityName: 'Payment'),
      );
    }
  }

  @override
  Future<Result<List<Payment>>> getPayments({
    String? employeeId,
    String? paymentMethod,
    DateRangeFilter? dateRange,
  }) async {
    final rangeFailure = InputValidators.validateDateRange(dateRange);
    if (rangeFailure != null) return Err<List<Payment>>(rangeFailure);

    try {
      var query = _client.from(PaymentSupabaseDto.tableName).select();
      if (employeeId != null) {
        query = query.eq('employee_id', employeeId);
      }
      if (paymentMethod != null) {
        query = query.eq('payment_method', paymentMethod.trim());
      }
      if (dateRange?.startDate != null) {
        query = query.gte(
          'payment_date',
          SupabaseHelpers.formatDateOnly(dateRange!.startDate!),
        );
      }
      if (dateRange?.endDate != null) {
        query = query.lte(
          'payment_date',
          SupabaseHelpers.formatDateOnly(dateRange!.endDate!),
        );
      }

      final rows = await query
          .order('payment_date', ascending: false)
          .order('created_at', ascending: false);

      return Ok<List<Payment>>(
        rows.map(PaymentSupabaseDto.fromSupabase).toList(growable: false),
      );
    } catch (error) {
      return Err<List<Payment>>(
        SupabaseHelpers.mapError(error, entityName: 'Payment'),
      );
    }
  }

  @override
  Stream<List<Payment>> watchPaymentsForOrder(String orderId) => _client
      .from(PaymentSupabaseDto.tableName)
      .stream(primaryKey: const <String>['payment_id'])
      .eq('order_id', orderId)
      .order('payment_date', ascending: false)
      .map(
        (rows) => rows
            .map(PaymentSupabaseDto.fromSupabase)
            .toList(growable: false),
      );

  @override
  Future<Result<void>> voidPayment({
    required String paymentId,
    required String orderId,
    required String actorEmployeeId,
    String? reason,
  }) async {
    try {
      await _client.rpc<void>(
        'rpc_void_payment',
        params: <String, dynamic>{
          'p_payment_id': paymentId,
          'p_order_id': orderId,
          'p_actor_employee_id': actorEmployeeId,
          'p_reason': reason,
        },
      );
      return const Ok<void>(null);
    } catch (error) {
      return Err<void>(
        SupabaseHelpers.mapError(
          error,
          entityName: 'Payment',
          entityId: paymentId,
        ),
      );
    }
  }
}
