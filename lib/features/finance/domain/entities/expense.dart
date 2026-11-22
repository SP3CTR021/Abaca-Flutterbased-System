import 'package:meta/meta.dart';

import '../../../../core/utils/decimal_precision.dart';

/// Operational expense logged by an employee (`expenses` table / collection).
///
/// Relationships:
/// - `N:1` child of `employees` (`expenses.employee_id`, `ON DELETE RESTRICT`).
@immutable
final class Expense {
  const Expense({
    required this.id,
    required this.employeeId,
    required this.expenseType,
    required this.amount,
    required this.date,
    this.notes,
    required this.createdAt,
    required this.updatedAt,
  });

  /// Primary key (`expense_id`).
  final String id;
  final String employeeId;
  final String expenseType;
  final double amount;
  final DateTime date;
  final String? notes;
  final DateTime createdAt;
  final DateTime updatedAt;

  Expense copyWith({
    String? id,
    String? employeeId,
    String? expenseType,
    double? amount,
    DateTime? date,
    String? notes,
    bool clearNotes = false,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) =>
      Expense(
        id: id ?? this.id,
        employeeId: employeeId ?? this.employeeId,
        expenseType: expenseType ?? this.expenseType,
        amount: amount ?? this.amount,
        date: date ?? this.date,
        notes: clearNotes ? null : (notes ?? this.notes),
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Expense &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          employeeId == other.employeeId &&
          expenseType == other.expenseType &&
          DecimalPrecision.equals2(amount, other.amount) &&
          date == other.date &&
          notes == other.notes &&
          createdAt == other.createdAt &&
          updatedAt == other.updatedAt;

  @override
  int get hashCode => Object.hash(
        runtimeType,
        id,
        employeeId,
        expenseType,
        DecimalPrecision.toMinorUnits(amount),
        date,
        notes,
        createdAt,
        updatedAt,
      );

  @override
  String toString() =>
      'Expense(id: $id, expenseType: $expenseType, amount: $amount, date: $date)';
}
