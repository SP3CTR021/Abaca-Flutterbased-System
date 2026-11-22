import 'package:meta/meta.dart';

import '../../../../core/utils/decimal_precision.dart';

/// Aggregated financial position across orders, payments, stock purchases, and
/// operational expenses over a date window.
///
/// Computed via Postgres SQL aggregates/RPC in Supabase and Firestore
/// `AggregateQuery` (`total_cost`, `amount_paid`, `amount`) / client sums.
@immutable
final class FinancialSummary {
  const FinancialSummary({
    required this.totalOrderValue,
    required this.totalPaymentsCollected,
    required this.totalReceivables,
    required this.totalStockInPurchaseCost,
    required this.totalOperationalExpenses,
  });

  final double totalOrderValue;
  final double totalPaymentsCollected;
  final double totalReceivables;
  final double totalStockInPurchaseCost;
  final double totalOperationalExpenses;

  /// Net cash flow (`collected - (stockPurchases + operationalExpenses)`).
  double get netCashFlow => DecimalPrecision.subtract2(
        totalPaymentsCollected,
        DecimalPrecision.add2(
          totalStockInPurchaseCost,
          totalOperationalExpenses,
        ),
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FinancialSummary &&
          runtimeType == other.runtimeType &&
          DecimalPrecision.equals2(totalOrderValue, other.totalOrderValue) &&
          DecimalPrecision.equals2(
            totalPaymentsCollected,
            other.totalPaymentsCollected,
          ) &&
          DecimalPrecision.equals2(totalReceivables, other.totalReceivables) &&
          DecimalPrecision.equals2(
            totalStockInPurchaseCost,
            other.totalStockInPurchaseCost,
          ) &&
          DecimalPrecision.equals2(
            totalOperationalExpenses,
            other.totalOperationalExpenses,
          );

  @override
  int get hashCode => Object.hash(
        runtimeType,
        DecimalPrecision.toMinorUnits(totalOrderValue),
        DecimalPrecision.toMinorUnits(totalPaymentsCollected),
        DecimalPrecision.toMinorUnits(totalReceivables),
        DecimalPrecision.toMinorUnits(totalStockInPurchaseCost),
        DecimalPrecision.toMinorUnits(totalOperationalExpenses),
      );
}
