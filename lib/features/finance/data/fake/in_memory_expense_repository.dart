import '../../../../core/data/fake/in_memory_database.dart';
import '../../../../core/data/input_validators.dart';
import '../../../../core/errors/app_failure.dart';
import '../../../../core/result/result.dart';
import '../../../../core/types/query_filters.dart';
import '../../../../core/utils/decimal_precision.dart';
import '../../../audit/domain/entities/audit_enums.dart';
import '../../../orders/domain/entities/order_status.dart';
import '../../domain/entities/expense.dart';
import '../../domain/entities/financial_summary.dart';
import '../../domain/repositories/expense_repository.dart';

/// Pure-Dart in-memory implementation of [ExpenseRepository].
final class InMemoryExpenseRepository implements ExpenseRepository {
  InMemoryExpenseRepository(this._db);

  final InMemoryDatabase _db;

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

    if (!_db.employees.containsKey(employeeId)) {
      return Err<Expense>(
        NotFoundFailure(
          entityName: 'Employee',
          entityId: employeeId,
          message: 'Employee $employeeId was not found.',
        ),
      );
    }

    final now = _db.nextTimestamp();
    final dateOnly = DateTime(date.year, date.month, date.day);
    final trimmedNotes = notes?.trim();
    final created = Expense(
      id: _db.nextId(),
      employeeId: employeeId,
      expenseType: expenseType.trim(),
      amount: DecimalPrecision.round2(amount),
      date: dateOnly,
      notes:
          (trimmedNotes == null || trimmedNotes.isEmpty) ? null : trimmedNotes,
      createdAt: now,
      updatedAt: now,
    );

    _db.expenses[created.id] = created;
    _db.recordAudit(
      actorEmployeeId: employeeId,
      action: AuditAction.created,
      entityType: AuditEntityType.expense,
      entityId: created.id,
      description: 'Logged expense ${created.expenseType} (${created.amount}).',
      createdAt: now,
    );
    _db.notify();
    return Ok<Expense>(created);
  }

  @override
  Future<Result<Expense>> getExpenseById(String id) async {
    final expense = _db.expenses[id];
    if (expense == null) {
      return Err<Expense>(
        NotFoundFailure(
          entityName: 'Expense',
          entityId: id,
          message: 'Expense $id was not found.',
        ),
      );
    }
    return Ok<Expense>(expense);
  }

  @override
  Future<Result<List<Expense>>> getExpenses({
    String? employeeId,
    String? expenseType,
    DateRangeFilter? dateRange,
  }) async {
    final rangeFailure = InputValidators.validateDateRange(dateRange);
    if (rangeFailure != null) return Err<List<Expense>>(rangeFailure);

    return Ok<List<Expense>>(
      _filterExpenses(
        employeeId: employeeId,
        expenseType: expenseType,
        dateRange: dateRange,
      ),
    );
  }

  @override
  Stream<List<Expense>> watchExpenses({
    String? employeeId,
    String? expenseType,
  }) =>
      _db.watch(
        () => _filterExpenses(
          employeeId: employeeId,
          expenseType: expenseType,
        ),
      );

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

    final existing = _db.expenses[expense.id];
    if (existing == null) {
      return Err<Expense>(
        NotFoundFailure(
          entityName: 'Expense',
          entityId: expense.id,
          message: 'Expense ${expense.id} was not found.',
        ),
      );
    }
    if (!_db.employees.containsKey(expense.employeeId)) {
      return Err<Expense>(
        NotFoundFailure(
          entityName: 'Employee',
          entityId: expense.employeeId,
          message: 'Employee ${expense.employeeId} was not found.',
        ),
      );
    }

    final now = _db.nextTimestamp();
    final dateOnly =
        DateTime(expense.date.year, expense.date.month, expense.date.day);
    final trimmedNotes = expense.notes?.trim();
    final updated = expense.copyWith(
      expenseType: expense.expenseType.trim(),
      amount: DecimalPrecision.round2(expense.amount),
      date: dateOnly,
      notes:
          (trimmedNotes == null || trimmedNotes.isEmpty) ? null : trimmedNotes,
      clearNotes: trimmedNotes == null || trimmedNotes.isEmpty,
      createdAt: existing.createdAt,
      updatedAt: now,
    );

    _db.expenses[updated.id] = updated;
    _db.recordAudit(
      actorEmployeeId: actorEmployeeId,
      action: AuditAction.updated,
      entityType: AuditEntityType.expense,
      entityId: updated.id,
      description: 'Updated expense ${updated.expenseType}.',
      createdAt: now,
    );
    _db.notify();
    return Ok<Expense>(updated);
  }

  @override
  Future<Result<void>> deleteExpense(
    String id, {
    String? actorEmployeeId,
  }) async {
    final existing = _db.expenses[id];
    if (existing == null) {
      return Err<void>(
        NotFoundFailure(
          entityName: 'Expense',
          entityId: id,
          message: 'Expense $id was not found.',
        ),
      );
    }

    _db.expenses.remove(id);
    _db.recordAudit(
      actorEmployeeId: actorEmployeeId,
      action: AuditAction.deleted,
      entityType: AuditEntityType.expense,
      entityId: id,
      description: 'Deleted expense ${existing.expenseType}.',
    );
    _db.notify();
    return const Ok<void>(null);
  }

  @override
  Future<Result<FinancialSummary>> getFinancialSummary({
    DateRangeFilter? dateRange,
  }) async {
    final rangeFailure = InputValidators.validateDateRange(dateRange);
    if (rangeFailure != null) return Err<FinancialSummary>(rangeFailure);

    var totalOrderValue = 0.0;
    var totalReceivables = 0.0;
    for (final order in _db.orders.values) {
      if (order.status == OrderStatus.cancelled) continue;
      if (dateRange != null && !dateRange.contains(order.orderDate)) continue;

      totalOrderValue = DecimalPrecision.add2(totalOrderValue, order.totalAmount);
      final paidForOrder = DecimalPrecision.sum2(
        _db.payments.values
            .where((p) => p.orderId == order.id)
            .map((p) => p.amountPaid),
      );
      final unpaid = DecimalPrecision.subtract2(order.totalAmount, paidForOrder);
      if (DecimalPrecision.compare2(unpaid, 0) > 0) {
        totalReceivables = DecimalPrecision.add2(totalReceivables, unpaid);
      }
    }

    final totalPaymentsCollected = DecimalPrecision.sum2(
      _db.payments.values
          .where((p) => dateRange == null || dateRange.contains(p.paymentDate))
          .map((p) => p.amountPaid),
    );

    final stockInCosts = <double>[];
    for (final header in _db.stockIns.values) {
      if (dateRange != null && !dateRange.contains(header.dateReceived)) {
        continue;
      }
      final items = _db.stockInItemsByStockInId[header.id] ?? const [];
      for (final item in items) {
        stockInCosts.add(item.totalCost);
      }
    }
    final totalStockInPurchaseCost = DecimalPrecision.sum2(stockInCosts);

    final totalOperationalExpenses = DecimalPrecision.sum2(
      _db.expenses.values
          .where((e) => dateRange == null || dateRange.contains(e.date))
          .map((e) => e.amount),
    );

    return Ok<FinancialSummary>(
      FinancialSummary(
        totalOrderValue: totalOrderValue,
        totalPaymentsCollected: totalPaymentsCollected,
        totalReceivables: totalReceivables,
        totalStockInPurchaseCost: totalStockInPurchaseCost,
        totalOperationalExpenses: totalOperationalExpenses,
      ),
    );
  }

  List<Expense> _filterExpenses({
    String? employeeId,
    String? expenseType,
    DateRangeFilter? dateRange,
  }) {
    final targetType = expenseType?.trim();
    final list = _db.expenses.values.where((expense) {
      if (employeeId != null && expense.employeeId != employeeId) return false;
      if (targetType != null && expense.expenseType != targetType) return false;
      if (dateRange != null && !dateRange.contains(expense.date)) return false;
      return true;
    }).toList()
      ..sort((a, b) {
        final dateCmp = b.date.compareTo(a.date);
        return dateCmp != 0 ? dateCmp : b.createdAt.compareTo(a.createdAt);
      });
    return List<Expense>.unmodifiable(list);
  }
}
