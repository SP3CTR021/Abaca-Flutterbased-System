import '../../../../core/result/result.dart';
import '../../../../core/types/query_filters.dart';
import '../entities/expense.dart';
import '../entities/financial_summary.dart';

/// Manages operational expenses and financial reporting (`expenses`).
abstract interface class ExpenseRepository {
  /// Logs a new operational expense (`amount >= 0`) and records an audit entry.
  Future<Result<Expense>> createExpense({
    required String employeeId,
    required String expenseType,
    required double amount,
    required DateTime date,
    String? notes,
  });

  /// Fetches an [Expense] by [id].
  Future<Result<Expense>> getExpenseById(String id);

  /// Queries operational expenses filtered by [employeeId], [expenseType],
  /// and/or [dateRange].
  Future<Result<List<Expense>>> getExpenses({
    String? employeeId,
    String? expenseType,
    DateRangeFilter? dateRange,
  });

  /// Streams operational expenses in real time.
  Stream<List<Expense>> watchExpenses({
    String? employeeId,
    String? expenseType,
  });

  /// Updates an existing expense and writes an `updated` audit log entry.
  Future<Result<Expense>> updateExpense(
    Expense expense, {
    String? actorEmployeeId,
  });

  /// Deletes an expense and logs a `deleted` audit entry.
  Future<Result<void>> deleteExpense(
    String id, {
    String? actorEmployeeId,
  });

  /// Computes a [FinancialSummary] over [dateRange] (excluding cancelled orders).
  Future<Result<FinancialSummary>> getFinancialSummary({
    DateRangeFilter? dateRange,
  });
}
