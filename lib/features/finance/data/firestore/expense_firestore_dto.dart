import 'package:cloud_firestore/cloud_firestore.dart' hide Order, ListEquality;

import '../../../../core/data/firestore/firestore_helpers.dart';
import '../../../../core/utils/decimal_precision.dart';
import '../../domain/entities/expense.dart';

/// Cloud Firestore DTO mapper for `expenses/{expenseId}` docs.
abstract final class ExpenseFirestoreDto {
  static Expense fromFirestore(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data()!;
    return Expense(
      id: doc.id,
      employeeId: data['employee_id'] as String,
      expenseType: data['expense_type'] as String,
      amount: FirestoreHelpers.parseDouble(data['amount']),
      date: FirestoreHelpers.fromDateOnlyTimestamp(data['date']),
      notes: data['notes'] as String?,
      createdAt: FirestoreHelpers.fromTimestamp(data['created_at']),
      updatedAt: FirestoreHelpers.fromTimestamp(data['updated_at']),
    );
  }

  static Map<String, dynamic> toFirestore({
    required String employeeId,
    required String employeeName,
    required String expenseType,
    required double amount,
    required DateTime date,
    String? notes,
    required DateTime createdAt,
    required DateTime updatedAt,
  }) {
    final trimmedNotes = notes?.trim();
    return <String, dynamic>{
      'employee_id': employeeId,
      'employee_name': employeeName,
      'expense_type': expenseType.trim(),
      'amount': DecimalPrecision.round2(amount),
      'date': FirestoreHelpers.toDateOnlyTimestamp(date),
      'notes': (trimmedNotes == null || trimmedNotes.isEmpty) ? null : trimmedNotes,
      'created_at': FirestoreHelpers.toTimestamp(createdAt),
      'updated_at': FirestoreHelpers.toTimestamp(updatedAt),
    };
  }
}
