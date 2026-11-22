import '../../../../core/data/fake/in_memory_database.dart';
import '../../../../core/data/input_validators.dart';
import '../../../../core/errors/app_failure.dart';
import '../../../../core/result/result.dart';
import '../../../../core/types/query_filters.dart';
import '../../../../core/utils/decimal_precision.dart';
import '../../../audit/domain/entities/audit_enums.dart';
import '../../../orders/domain/entities/order_status.dart';
import '../../domain/entities/payment.dart';
import '../../domain/repositories/payment_repository.dart';

/// Pure-Dart in-memory implementation of [PaymentRepository].
final class InMemoryPaymentRepository implements PaymentRepository {
  InMemoryPaymentRepository(this._db);

  final InMemoryDatabase _db;

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

    final order = _db.orders[orderId];
    if (order == null) {
      return Err<Payment>(
        NotFoundFailure(
          entityName: 'Order',
          entityId: orderId,
          message: 'Order $orderId was not found.',
        ),
      );
    }
    if (!_db.employees.containsKey(employeeId)) {
      return Err<Payment>(
        NotFoundFailure(
          entityName: 'Employee',
          entityId: employeeId,
          message: 'Employee $employeeId was not found.',
        ),
      );
    }
    if (order.status != OrderStatus.stocked &&
        order.status != OrderStatus.delivered) {
      return Err<Payment>(
        InvalidStateTransitionFailure(
          entityName: 'Order',
          currentState: order.status.dbValue,
          attemptedAction: 'record_payment',
          message:
              'Payments can only be recorded for stocked or delivered orders.',
        ),
      );
    }

    final amount = DecimalPrecision.round2(amountPaid);
    final existingPaid = DecimalPrecision.sum2(
      _db.payments.values
          .where((p) => p.orderId == orderId)
          .map((p) => p.amountPaid),
    );
    final nextPaid = DecimalPrecision.add2(existingPaid, amount);
    if (DecimalPrecision.compare2(nextPaid, order.totalAmount) > 0) {
      return Err<Payment>(
        ValidationFailure(
          message:
              'Payment exceeds remaining balance (paid: $existingPaid, order total: ${order.totalAmount}).',
          fieldErrors: const <String, String>{
            'amountPaid': 'Amount exceeds order remaining balance.',
          },
        ),
      );
    }

    final now = _db.nextTimestamp();
    final dateOnly =
        DateTime(paymentDate.year, paymentDate.month, paymentDate.day);
    final trimmedRef = referenceNumber?.trim();
    final trimmedNotes = notes?.trim();
    final created = Payment(
      id: _db.nextId(),
      orderId: orderId,
      employeeId: employeeId,
      amountPaid: amount,
      paymentDate: dateOnly,
      paymentMethod: paymentMethod.trim(),
      referenceNumber:
          (trimmedRef == null || trimmedRef.isEmpty) ? null : trimmedRef,
      notes:
          (trimmedNotes == null || trimmedNotes.isEmpty) ? null : trimmedNotes,
      createdAt: now,
      updatedAt: now,
    );

    _db.payments[created.id] = created;
    _db.recordAudit(
      actorEmployeeId: employeeId,
      action: AuditAction.paymentRecorded,
      entityType: AuditEntityType.payment,
      entityId: created.id,
      description:
          'Recorded ${created.paymentMethod} payment of ${created.amountPaid} against order $orderId.',
      createdAt: now,
    );
    _db.notify();
    return Ok<Payment>(created);
  }

  @override
  Future<Result<Payment>> getPaymentById(
    String id, {
    String? orderId,
  }) async {
    final payment = _db.payments[id];
    if (payment == null || (orderId != null && payment.orderId != orderId)) {
      return Err<Payment>(
        NotFoundFailure(
          entityName: 'Payment',
          entityId: id,
          message: 'Payment $id was not found.',
        ),
      );
    }
    return Ok<Payment>(payment);
  }

  @override
  Future<Result<List<Payment>>> getPaymentsForOrder(String orderId) async =>
      Ok<List<Payment>>(_filterOrderPayments(orderId));

  @override
  Future<Result<List<Payment>>> getPayments({
    String? employeeId,
    String? paymentMethod,
    DateRangeFilter? dateRange,
  }) async {
    final rangeFailure = InputValidators.validateDateRange(dateRange);
    if (rangeFailure != null) return Err<List<Payment>>(rangeFailure);

    final targetMethod = paymentMethod?.trim();
    final list = _db.payments.values.where((payment) {
      if (employeeId != null && payment.employeeId != employeeId) return false;
      if (targetMethod != null && payment.paymentMethod != targetMethod) {
        return false;
      }
      if (dateRange != null && !dateRange.contains(payment.paymentDate)) {
        return false;
      }
      return true;
    }).toList()
      ..sort((a, b) {
        final dateCmp = b.paymentDate.compareTo(a.paymentDate);
        return dateCmp != 0 ? dateCmp : b.createdAt.compareTo(a.createdAt);
      });
    return Ok<List<Payment>>(List<Payment>.unmodifiable(list));
  }

  @override
  Stream<List<Payment>> watchPaymentsForOrder(String orderId) =>
      _db.watch(() => _filterOrderPayments(orderId));

  @override
  Future<Result<void>> voidPayment({
    required String paymentId,
    required String orderId,
    required String actorEmployeeId,
    String? reason,
  }) async {
    final payment = _db.payments[paymentId];
    if (payment == null || payment.orderId != orderId) {
      return Err<void>(
        NotFoundFailure(
          entityName: 'Payment',
          entityId: paymentId,
          message: 'Payment $paymentId was not found for order $orderId.',
        ),
      );
    }

    _db.payments.remove(paymentId);
    _db.recordAudit(
      actorEmployeeId: actorEmployeeId,
      action: AuditAction.paymentVoided,
      entityType: AuditEntityType.payment,
      entityId: paymentId,
      description: (reason != null && reason.trim().isNotEmpty)
          ? reason.trim()
          : 'Voided payment entry.',
      oldValues: <String, Object?>{
        'order_id': orderId,
        'amount_paid': payment.amountPaid,
        'payment_method': payment.paymentMethod,
      },
    );
    _db.notify();
    return const Ok<void>(null);
  }

  List<Payment> _filterOrderPayments(String orderId) {
    final list = _db.payments.values
        .where((p) => p.orderId == orderId)
        .toList()
      ..sort((a, b) {
        final dateCmp = b.paymentDate.compareTo(a.paymentDate);
        return dateCmp != 0 ? dateCmp : b.createdAt.compareTo(a.createdAt);
      });
    return List<Payment>.unmodifiable(list);
  }
}
