import '../../../../core/result/result.dart';
import '../../../../core/types/query_filters.dart';
import '../entities/payment.dart';

/// Manages customer order payments (`payments` table / `orders/{id}/payments`).
abstract interface class PaymentRepository {
  /// Atomically records a payment against a `stocked` or `delivered` [orderId].
  ///
  /// Enforces `amountPaid > 0` and rejects payments that would push total
  /// cumulative payments above `order.totalAmount` (`ValidationFailure` /
  /// `InvalidStateTransitionFailure`). Syncs `paid_amount` on Firestore parent
  /// order and records a `paymentRecorded` audit entry.
  Future<Result<Payment>> recordPayment({
    required String orderId,
    required String employeeId,
    required double amountPaid,
    required DateTime paymentDate,
    required String paymentMethod,
    String? referenceNumber,
    String? notes,
  });

  /// Fetches a [Payment] by [id] (optionally scoped by [orderId] for direct
  /// subcollection lookup in Firestore).
  Future<Result<Payment>> getPaymentById(
    String id, {
    String? orderId,
  });

  /// Lists all payments recorded for [orderId].
  Future<Result<List<Payment>>> getPaymentsForOrder(String orderId);

  /// Queries payments across orders via SQL table (Supabase) or
  /// `collectionGroup('payments')` (Firestore).
  Future<Result<List<Payment>>> getPayments({
    String? employeeId,
    String? paymentMethod,
    DateRangeFilter? dateRange,
  });

  /// Streams payments for a specific [orderId] in real time.
  Stream<List<Payment>> watchPaymentsForOrder(String orderId);

  /// Voids (deletes) an erroneous payment, updates Firestore `paid_amount`,
  /// and writes a `paymentVoided` audit log entry.
  Future<Result<void>> voidPayment({
    required String paymentId,
    required String orderId,
    required String actorEmployeeId,
    String? reason,
  });
}
