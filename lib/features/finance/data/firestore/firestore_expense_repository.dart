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
import '../../domain/entities/expense.dart';
import '../../domain/entities/financial_summary.dart';
import '../../domain/repositories/expense_repository.dart';
import 'expense_firestore_dto.dart';
import 'payment_firestore_dto.dart';

/// Cloud Firestore implementation of [ExpenseRepository].
final class FirestoreExpenseRepository implements ExpenseRepository {
  FirestoreExpenseRepository(this._firestore);

  final FirebaseFirestore _firestore;

  CollectionReference<Map<String, dynamic>> get _expenses =>
      _firestore.collection(FirestoreCollections.expenses);

  @override
  Future<Result<Expense>> createExpense({
    required String employeeId,
    required String expenseType,
    required double amount,
    required DateTime date,
    String? notes,
  }) async {
    final errors = <String, String>{};
    InputValidators.requireNonEmpty(errors, 'employeeId', employeeId);
    InputValidators.requireNonEmpty(errors, 'expenseType', expenseType);
    InputValidators.requireNonNegative(errors, 'amount', amount);
    InputValidators.validateMaxLength(errors, 'notes', notes, 1000);
    final validation = InputValidators.toFailure(errors);
    if (validation != null) return Err<Expense>(validation);

    try {
      final empRef =
          _firestore.collection(FirestoreCollections.employees).doc(employeeId);
      final expenseRef = _expenses.doc();
      final now = DateTime.now().toUtc();
      final dateOnly = DateTime(date.year, date.month, date.day);
      final roundedAmount = DecimalPrecision.round2(amount);

      final created = await _firestore.runTransaction<Expense>((tx) async {
        final empSnap = await tx.get(empRef);
        if (!empSnap.exists || empSnap.data() == null) {
          throw NotFoundFailure(
            entityName: 'Employee',
            entityId: employeeId,
            message: 'Employee $employeeId was not found.',
          );
        }
        final empData = empSnap.data()!;
        final empName = FirestoreHelpers.formatFullName(
          firstName: empData['first_name'] as String,
          middleName: empData['middle_name'] as String?,
          lastName: empData['last_name'] as String,
        );

        final entity = Expense(
          id: expenseRef.id,
          employeeId: employeeId,
          expenseType: expenseType.trim(),
          amount: roundedAmount,
          date: dateOnly,
          notes: notes?.trim().isEmpty == true ? null : notes?.trim(),
          createdAt: now,
          updatedAt: now,
        );

        tx.set(
          expenseRef,
          ExpenseFirestoreDto.toFirestore(
            employeeId: entity.employeeId,
            employeeName: empName,
            expenseType: entity.expenseType,
            amount: entity.amount,
            date: entity.date,
            notes: entity.notes,
            createdAt: now,
            updatedAt: now,
          ),
        );

        FirestoreAuditRepository.setAuditInTransaction(
          tx,
          _firestore,
          actorEmployeeId: employeeId,
          action: AuditAction.created,
          entityType: AuditEntityType.expense,
          entityId: entity.id,
          description:
              'Logged expense ${entity.expenseType} (${entity.amount}).',
          timestamp: now,
        );

        return entity;
      });

      return Ok<Expense>(created);
    } catch (error) {
      return Err<Expense>(
        FirestoreHelpers.mapError(error, entityName: 'Expense'),
      );
    }
  }

  @override
  Future<Result<Expense>> getExpenseById(String id) async {
    try {
      final doc = await _expenses.doc(id).get();
      if (!doc.exists || doc.data() == null) {
        return Err<Expense>(
          NotFoundFailure(
            entityName: 'Expense',
            entityId: id,
            message: 'Expense $id was not found.',
          ),
        );
      }
      return Ok<Expense>(ExpenseFirestoreDto.fromFirestore(doc));
    } catch (error) {
      return Err<Expense>(
        FirestoreHelpers.mapError(error, entityName: 'Expense', entityId: id),
      );
    }
  }

  @override
  Future<Result<List<Expense>>> getExpenses({
    String? employeeId,
    String? expenseType,
    DateRangeFilter? dateRange,
  }) async {
    final rangeFailure = InputValidators.validateDateRange(dateRange);
    if (rangeFailure != null) return Err<List<Expense>>(rangeFailure);

    try {
      Query<Map<String, dynamic>> query = _expenses;
      if (employeeId != null) {
        query = query.where('employee_id', isEqualTo: employeeId);
      }
      if (expenseType != null) {
        query = query.where('expense_type', isEqualTo: expenseType.trim());
      }

      final snapshot = await query.orderBy('date', descending: true).get();
      var list = snapshot.docs.map(ExpenseFirestoreDto.fromFirestore);
      if (dateRange != null) {
        list = list.where((e) => dateRange.contains(e.date));
      }
      return Ok<List<Expense>>(list.toList(growable: false));
    } catch (error) {
      return Err<List<Expense>>(
        FirestoreHelpers.mapError(error, entityName: 'Expense'),
      );
    }
  }

  @override
  Stream<List<Expense>> watchExpenses({
    String? employeeId,
    String? expenseType,
  }) {
    Query<Map<String, dynamic>> query = _expenses;
    if (employeeId != null) {
      query = query.where('employee_id', isEqualTo: employeeId);
    }
    if (expenseType != null) {
      query = query.where('expense_type', isEqualTo: expenseType.trim());
    }
    return query.orderBy('date', descending: true).snapshots().map(
          (snapshot) => snapshot.docs
              .map(ExpenseFirestoreDto.fromFirestore)
              .toList(growable: false),
        );
  }

  @override
  Future<Result<Expense>> updateExpense(
    Expense expense, {
    String? actorEmployeeId,
  }) async {
    final errors = <String, String>{};
    InputValidators.requireNonEmpty(errors, 'expenseType', expense.expenseType);
    InputValidators.requireNonNegative(errors, 'amount', expense.amount);
    InputValidators.validateMaxLength(errors, 'notes', expense.notes, 1000);
    final validation = InputValidators.toFailure(errors);
    if (validation != null) return Err<Expense>(validation);

    try {
      final docRef = _expenses.doc(expense.id);
      final empRef = _firestore
          .collection(FirestoreCollections.employees)
          .doc(expense.employeeId);
      final now = DateTime.now().toUtc();
      final dateOnly =
          DateTime(expense.date.year, expense.date.month, expense.date.day);
      final roundedAmount = DecimalPrecision.round2(expense.amount);

      final updated = await _firestore.runTransaction<Expense>((tx) async {
        // 1. ALL READS FIRST
        final docSnap = await tx.get(docRef);
        if (!docSnap.exists || docSnap.data() == null) {
          throw NotFoundFailure(
            entityName: 'Expense',
            entityId: expense.id,
            message: 'Expense ${expense.id} was not found.',
          );
        }
        final empSnap = await tx.get(empRef);
        if (!empSnap.exists || empSnap.data() == null) {
          throw NotFoundFailure(
            entityName: 'Employee',
            entityId: expense.employeeId,
            message: 'Employee ${expense.employeeId} was not found.',
          );
        }
        final existing = ExpenseFirestoreDto.fromFirestore(docSnap);
        final empData = empSnap.data()!;
        final empName = FirestoreHelpers.formatFullName(
          firstName: empData['first_name'] as String,
          middleName: empData['middle_name'] as String?,
          lastName: empData['last_name'] as String,
        );

        final next = expense.copyWith(
          expenseType: expense.expenseType.trim(),
          amount: roundedAmount,
          date: dateOnly,
          notes:
              expense.notes?.trim().isEmpty == true ? null : expense.notes?.trim(),
          clearNotes: expense.notes?.trim().isEmpty == true,
          createdAt: existing.createdAt,
          updatedAt: now,
        );

        // 2. ALL WRITES AFTER READS
        tx.update(
          docRef,
          ExpenseFirestoreDto.toFirestore(
            employeeId: next.employeeId,
            employeeName: empName,
            expenseType: next.expenseType,
            amount: next.amount,
            date: next.date,
            notes: next.notes,
            createdAt: existing.createdAt,
            updatedAt: now,
          ),
        );

        FirestoreAuditRepository.setAuditInTransaction(
          tx,
          _firestore,
          actorEmployeeId: actorEmployeeId,
          action: AuditAction.updated,
          entityType: AuditEntityType.expense,
          entityId: next.id,
          description: 'Updated expense ${next.expenseType}.',
          timestamp: now,
        );

        return next;
      });

      return Ok<Expense>(updated);
    } catch (error) {
      return Err<Expense>(
        FirestoreHelpers.mapError(
          error,
          entityName: 'Expense',
          entityId: expense.id,
        ),
      );
    }
  }

  @override
  Future<Result<void>> deleteExpense(
    String id, {
    String? actorEmployeeId,
  }) async {
    try {
      final docRef = _expenses.doc(id);
      final doc = await docRef.get();
      if (!doc.exists || doc.data() == null) {
        return Err<void>(
          NotFoundFailure(
            entityName: 'Expense',
            entityId: id,
            message: 'Expense $id was not found.',
          ),
        );
      }
      final existing = ExpenseFirestoreDto.fromFirestore(doc);

      final batch = _firestore.batch();
      batch.delete(docRef);
      FirestoreAuditRepository.setAuditInBatch(
        batch,
        _firestore,
        actorEmployeeId: actorEmployeeId,
        action: AuditAction.deleted,
        entityType: AuditEntityType.expense,
        entityId: id,
        description: 'Deleted expense ${existing.expenseType}.',
      );
      await batch.commit();
      return const Ok<void>(null);
    } catch (error) {
      return Err<void>(
        FirestoreHelpers.mapError(error, entityName: 'Expense', entityId: id),
      );
    }
  }

  @override
  Future<Result<FinancialSummary>> getFinancialSummary({
    DateRangeFilter? dateRange,
  }) async {
    final rangeFailure = InputValidators.validateDateRange(dateRange);
    if (rangeFailure != null) return Err<FinancialSummary>(rangeFailure);

    try {
      // Firestore lacks SQL JOIN + expression SUM(a * b); read orders,
      // payments, and stock_in items (with precomputed `total_cost`) and use
      // server-side AggregateQuery on expenses when unfiltered.
      final ordersFuture =
          _firestore.collection(FirestoreCollections.orders).get();
      final paymentsFuture = _firestore
          .collectionGroup(FirestoreCollections.paymentsSubcollection)
          .get();
      final stockInItemsFuture = _firestore
          .collectionGroup(FirestoreCollections.stockInItemsSubcollection)
          .get();

      double totalOperationalExpenses;
      if (dateRange == null) {
        final expAgg = await _expenses.aggregate(sum('amount')).get();
        totalOperationalExpenses =
            DecimalPrecision.round2(expAgg.getSum('amount') ?? 0.0);
      } else {
        final expSnap = await _expenses.get();
        final expValues = expSnap.docs
            .map(ExpenseFirestoreDto.fromFirestore)
            .where((e) => dateRange.contains(e.date))
            .map((e) => e.amount);
        totalOperationalExpenses = DecimalPrecision.sum2(expValues);
      }

      final ordersSnap = await ordersFuture;
      final paymentsSnap = await paymentsFuture;
      final stockInItemsSnap = await stockInItemsFuture;

      var totalOrderValue = 0.0;
      var totalReceivables = 0.0;
      for (final doc in ordersSnap.docs) {
        final order = OrderFirestoreDto.fromFirestore(doc);
        if (order.status == OrderStatus.cancelled) continue;
        if (dateRange != null && !dateRange.contains(order.orderDate)) continue;

        totalOrderValue = DecimalPrecision.add2(totalOrderValue, order.totalAmount);
        final paidAmount =
            FirestoreHelpers.parseDouble(doc.data()['paid_amount']);
        final unpaid = DecimalPrecision.subtract2(order.totalAmount, paidAmount);
        if (DecimalPrecision.compare2(unpaid, 0) > 0) {
          totalReceivables = DecimalPrecision.add2(totalReceivables, unpaid);
        }
      }

      final collectedPayments = paymentsSnap.docs
          .map(PaymentFirestoreDto.fromFirestore)
          .where((p) => dateRange == null || dateRange.contains(p.paymentDate))
          .map((p) => p.amountPaid);
      final totalPaymentsCollected = DecimalPrecision.sum2(collectedPayments);

      final itemCosts = <double>[];
      for (final doc in stockInItemsSnap.docs) {
        final data = doc.data();
        if (dateRange != null && data['date_received'] != null) {
          final received =
              FirestoreHelpers.fromDateOnlyTimestamp(data['date_received']);
          if (!dateRange.contains(received)) continue;
        }
        final storedTotal = data['total_cost'];
        if (storedTotal != null) {
          itemCosts.add(FirestoreHelpers.parseDouble(storedTotal));
        } else {
          final qty = FirestoreHelpers.parseDouble(data['quantity_kg']);
          final cost = FirestoreHelpers.parseDouble(data['cost_per_kg']);
          itemCosts.add(DecimalPrecision.multiply2(qty, cost));
        }
      }
      final totalStockInPurchaseCost = DecimalPrecision.sum2(itemCosts);

      return Ok<FinancialSummary>(
        FinancialSummary(
          totalOrderValue: totalOrderValue,
          totalPaymentsCollected: totalPaymentsCollected,
          totalReceivables: totalReceivables,
          totalStockInPurchaseCost: totalStockInPurchaseCost,
          totalOperationalExpenses: totalOperationalExpenses,
        ),
      );
    } catch (error) {
      return Err<FinancialSummary>(
        FirestoreHelpers.mapError(error, entityName: 'FinancialSummary'),
      );
    }
  }
}
