import 'package:cloud_firestore/cloud_firestore.dart' hide Order, ListEquality;

import '../../../../core/data/firestore/firestore_collections.dart';
import '../../../../core/data/firestore/firestore_helpers.dart';
import '../../../../core/data/input_validators.dart';
import '../../../../core/errors/app_failure.dart';
import '../../../../core/result/result.dart';
import '../../../../core/types/query_filters.dart';
import '../../../../core/utils/decimal_precision.dart';
import '../../../audit/data/firestore/firestore_audit_repository.dart';
import '../../../audit/domain/entities/audit_enums.dart';
import '../../../orders/data/firestore/order_firestore_dto.dart';
import '../../../orders/domain/entities/order_status.dart';
import '../../domain/entities/payment.dart';
import '../../domain/repositories/payment_repository.dart';
import 'payment_firestore_dto.dart';

/// Cloud Firestore implementation of [PaymentRepository].
///
/// Stores payments in subcollection `orders/{orderId}/payments/{paymentId}`
/// (mirroring `order_id` and `payment_id` for `collectionGroup('payments')`
/// queries) and atomically maintains `orders/{orderId}.paid_amount` inside
/// `runTransaction` to enforce overpayment protection.
final class FirestorePaymentRepository implements PaymentRepository {
  FirestorePaymentRepository(this._firestore);

  final FirebaseFirestore _firestore;

  CollectionReference<Map<String, dynamic>> _orderPayments(String orderId) =>
      _firestore
          .collection(FirestoreCollections.orders)
          .doc(orderId)
          .collection(FirestoreCollections.paymentsSubcollection);

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
      final now = DateTime.now().toUtc();
      final dateOnly =
          DateTime(paymentDate.year, paymentDate.month, paymentDate.day);
      final amount = DecimalPrecision.round2(amountPaid);
      final orderRef =
          _firestore.collection(FirestoreCollections.orders).doc(orderId);
      final empRef =
          _firestore.collection(FirestoreCollections.employees).doc(employeeId);
      final paymentRef = _orderPayments(orderId).doc();

      final created = await _firestore.runTransaction<Payment>((tx) async {
        // 1. ALL READS FIRST
        final orderSnap = await tx.get(orderRef);
        if (!orderSnap.exists || orderSnap.data() == null) {
          throw NotFoundFailure(
            entityName: 'Order',
            entityId: orderId,
            message: 'Order $orderId was not found.',
          );
        }
        final empSnap = await tx.get(empRef);
        if (!empSnap.exists || empSnap.data() == null) {
          throw NotFoundFailure(
            entityName: 'Employee',
            entityId: employeeId,
            message: 'Employee $employeeId was not found.',
          );
        }

        final order = OrderFirestoreDto.fromFirestore(orderSnap);
        if (order.status != OrderStatus.stocked &&
            order.status != OrderStatus.delivered) {
          throw InvalidStateTransitionFailure(
            entityName: 'Order',
            currentState: order.status.dbValue,
            attemptedAction: 'record_payment',
            message:
                'Payments can only be recorded for stocked or delivered orders.',
          );
        }

        final existingPaid =
            FirestoreHelpers.parseDouble(orderSnap.data()!['paid_amount']);
        final nextPaid = DecimalPrecision.add2(existingPaid, amount);
        if (DecimalPrecision.compare2(nextPaid, order.totalAmount) > 0) {
          throw ValidationFailure(
            message:
                'Payment exceeds remaining balance (paid: $existingPaid, order total: ${order.totalAmount}).',
            fieldErrors: const <String, String>{
              'amountPaid': 'Amount exceeds order remaining balance.',
            },
          );
        }

        final entity = Payment(
          id: paymentRef.id,
          orderId: orderId,
          employeeId: employeeId,
          amountPaid: amount,
          paymentDate: dateOnly,
          paymentMethod: paymentMethod.trim(),
          referenceNumber: referenceNumber?.trim().isEmpty == true
              ? null
              : referenceNumber?.trim(),
          notes: notes?.trim().isEmpty == true ? null : notes?.trim(),
          createdAt: now,
          updatedAt: now,
        );

        // 2. ALL WRITES AFTER READS
        tx.set(
          paymentRef,
          PaymentFirestoreDto.toFirestore(
            paymentId: entity.id,
            orderId: entity.orderId,
            employeeId: entity.employeeId,
            amountPaid: entity.amountPaid,
            paymentDate: entity.paymentDate,
            paymentMethod: entity.paymentMethod,
            referenceNumber: entity.referenceNumber,
            notes: entity.notes,
            createdAt: now,
            updatedAt: now,
          ),
        );

        tx.update(orderRef, <String, dynamic>{
          'paid_amount': nextPaid,
          'updated_at': FirestoreHelpers.toTimestamp(now),
        });

        FirestoreAuditRepository.setAuditInTransaction(
          tx,
          _firestore,
          actorEmployeeId: employeeId,
          action: AuditAction.paymentRecorded,
          entityType: AuditEntityType.payment,
          entityId: entity.id,
          description:
              'Recorded ${entity.paymentMethod} payment of ${entity.amountPaid} against order $orderId.',
          timestamp: now,
        );

        return entity;
      });

      return Ok<Payment>(created);
    } catch (error) {
      return Err<Payment>(
        FirestoreHelpers.mapError(error, entityName: 'Payment'),
      );
    }
  }

  @override
  Future<Result<Payment>> getPaymentById(
    String id, {
    String? orderId,
  }) async {
    try {
      if (orderId != null) {
        final doc = await _orderPayments(orderId).doc(id).get();
        if (!doc.exists || doc.data() == null) {
          return Err<Payment>(
            NotFoundFailure(
              entityName: 'Payment',
              entityId: id,
              message: 'Payment $id was not found.',
            ),
          );
        }
        return Ok<Payment>(PaymentFirestoreDto.fromFirestore(doc));
      }

      final snapshot = await _firestore
          .collectionGroup(FirestoreCollections.paymentsSubcollection)
          .where('payment_id', isEqualTo: id)
          .limit(1)
          .get();
      if (snapshot.docs.isEmpty) {
        return Err<Payment>(
          NotFoundFailure(
            entityName: 'Payment',
            entityId: id,
            message: 'Payment $id was not found.',
          ),
        );
      }
      return Ok<Payment>(
        PaymentFirestoreDto.fromFirestore(snapshot.docs.first),
      );
    } catch (error) {
      return Err<Payment>(
        FirestoreHelpers.mapError(error, entityName: 'Payment', entityId: id),
      );
    }
  }

  @override
  Future<Result<List<Payment>>> getPaymentsForOrder(String orderId) async {
    try {
      final snapshot = await _orderPayments(orderId)
          .orderBy('payment_date', descending: true)
          .get();

      return Ok<List<Payment>>(
        snapshot.docs
            .map(PaymentFirestoreDto.fromFirestore)
            .toList(growable: false),
      );
    } catch (error) {
      return Err<List<Payment>>(
        FirestoreHelpers.mapError(error, entityName: 'Payment'),
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
      Query<Map<String, dynamic>> query = _firestore.collectionGroup(
        FirestoreCollections.paymentsSubcollection,
      );
      if (employeeId != null) {
        query = query.where('employee_id', isEqualTo: employeeId);
      } else if (paymentMethod != null) {
        query = query.where('payment_method', isEqualTo: paymentMethod.trim());
      }

      final snapshot =
          await query.orderBy('payment_date', descending: true).get();

      var list = snapshot.docs.map(PaymentFirestoreDto.fromFirestore);
      if (employeeId != null && paymentMethod != null) {
        final targetMethod = paymentMethod.trim();
        list = list.where((p) => p.paymentMethod == targetMethod);
      }
      if (dateRange != null) {
        list = list.where((p) => dateRange.contains(p.paymentDate));
      }
      return Ok<List<Payment>>(list.toList(growable: false));
    } catch (error) {
      return Err<List<Payment>>(
        FirestoreHelpers.mapError(error, entityName: 'Payment'),
      );
    }
  }

  @override
  Stream<List<Payment>> watchPaymentsForOrder(String orderId) =>
      _orderPayments(orderId)
          .orderBy('payment_date', descending: true)
          .snapshots()
          .map(
            (snapshot) => snapshot.docs
                .map(PaymentFirestoreDto.fromFirestore)
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
      final orderRef =
          _firestore.collection(FirestoreCollections.orders).doc(orderId);
      final paymentRef = _orderPayments(orderId).doc(paymentId);
      final now = DateTime.now().toUtc();

      await _firestore.runTransaction<void>((tx) async {
        // 1. ALL READS FIRST
        final orderSnap = await tx.get(orderRef);
        final paymentSnap = await tx.get(paymentRef);

        if (!paymentSnap.exists || paymentSnap.data() == null) {
          throw NotFoundFailure(
            entityName: 'Payment',
            entityId: paymentId,
            message: 'Payment $paymentId was not found for order $orderId.',
          );
        }
        if (!orderSnap.exists || orderSnap.data() == null) {
          throw NotFoundFailure(
            entityName: 'Order',
            entityId: orderId,
            message: 'Order $orderId was not found.',
          );
        }

        final payment = PaymentFirestoreDto.fromFirestore(paymentSnap);
        final currentPaid =
            FirestoreHelpers.parseDouble(orderSnap.data()!['paid_amount']);
        final subtracted =
            DecimalPrecision.subtract2(currentPaid, payment.amountPaid);
        final nextPaid =
            DecimalPrecision.compare2(subtracted, 0) < 0 ? 0.0 : subtracted;

        // 2. ALL WRITES AFTER READS
        tx.delete(paymentRef);
        tx.update(orderRef, <String, dynamic>{
          'paid_amount': nextPaid,
          'updated_at': FirestoreHelpers.toTimestamp(now),
        });

        FirestoreAuditRepository.setAuditInTransaction(
          tx,
          _firestore,
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
          timestamp: now,
        );
      });

      return const Ok<void>(null);
    } catch (error) {
      return Err<void>(
        FirestoreHelpers.mapError(
          error,
          entityName: 'Payment',
          entityId: paymentId,
        ),
      );
    }
  }
}
