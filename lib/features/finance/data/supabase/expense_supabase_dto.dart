import '../../../../core/data/supabase/supabase_helpers.dart';
import '../../../../core/utils/decimal_precision.dart';
import '../../domain/entities/expense.dart';
import '../../domain/entities/financial_summary.dart';

/// Supabase DTO mapper for `expenses` and `rpc_get_financial_summary`.
abstract final class ExpenseSupabaseDto {
  static const String tableName = 'expenses';

  static Expense fromSupabase(Map<String, dynamic> row) => Expense(
        id: row['expense_id'] as String,
        employeeId: row['employee_id'] as String,
        expenseType: row['expense_type'] as String,
        amount: SupabaseHelpers.parseDouble(row['amount']),
        date: SupabaseHelpers.parseDateOnly(row['date']),
        notes: row['notes'] as String?,
        createdAt: SupabaseHelpers.parseTimestamp(row['created_at']),
        updatedAt: SupabaseHelpers.parseTimestamp(row['updated_at']),
      );

  static Map<String, dynamic> toInsertMap({
    required String employeeId,
    required String expenseType,
    required double amount,
    required DateTime date,
    String? notes,
  }) =>
      <String, dynamic>{
        'employee_id': employeeId,
        'expense_type': expenseType.trim(),
        'amount': DecimalPrecision.round2(amount),
        'date': SupabaseHelpers.formatDateOnly(date),
        'notes': _trimOrNull(notes),
      };

  static Map<String, dynamic> toUpdateMap(Expense expense) => <String, dynamic>{
        'employee_id': expense.employeeId,
        'expense_type': expense.expenseType.trim(),
        'amount': DecimalPrecision.round2(expense.amount),
        'date': SupabaseHelpers.formatDateOnly(expense.date),
        'notes': _trimOrNull(expense.notes),
      };

  static FinancialSummary summaryFromRpc(Map<String, dynamic> json) =>
      FinancialSummary(
        totalOrderValue: SupabaseHelpers.parseDouble(json['total_order_value']),
        totalPaymentsCollected:
            SupabaseHelpers.parseDouble(json['total_payments_collected']),
        totalReceivables: SupabaseHelpers.parseDouble(json['total_receivables']),
        totalStockInPurchaseCost:
            SupabaseHelpers.parseDouble(json['total_stock_in_purchase_cost']),
        totalOperationalExpenses:
            SupabaseHelpers.parseDouble(json['total_operational_expenses']),
      );

  static String? _trimOrNull(String? value) {
    final trimmed = value?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }
}
