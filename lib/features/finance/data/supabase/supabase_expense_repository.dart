import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/data/input_validators.dart';
import '../../../../core/data/supabase/supabase_helpers.dart';
import '../../../../core/errors/app_failure.dart';
import '../../../../core/result/result.dart';
import '../../../../core/types/query_filters.dart';
import '../../../audit/data/supabase/supabase_audit_repository.dart';
import '../../../audit/domain/entities/audit_enums.dart';
import '../../domain/entities/expense.dart';
import '../../domain/entities/financial_summary.dart';
import '../../domain/repositories/expense_repository.dart';
import 'expense_supabase_dto.dart';

/// PostgreSQL / Supabase implementation of [ExpenseRepository].
final class SupabaseExpenseRepository implements ExpenseRepository {
  SupabaseExpenseRepository(this._client);

  final SupabaseClient _client;

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
      final row = await _client
          .from(ExpenseSupabaseDto.tableName)
          .insert(
            ExpenseSupabaseDto.toInsertMap(
              employeeId: employeeId,
              expenseType: expenseType,
              amount: amount,
              date: date,
              notes: notes,
            ),
          )
          .select()
          .single();

      final created = ExpenseSupabaseDto.fromSupabase(row);
      await SupabaseAuditRepository.tryRecordAudit(
        _client,
        actorEmployeeId: employeeId,
        action: AuditAction.created,
        entityType: AuditEntityType.expense,
        entityId: created.id,
        description:
            'Logged expense ${created.expenseType} (${created.amount}).',
      );
      return Ok<Expense>(created);
    } catch (error) {
      return Err<Expense>(
        SupabaseHelpers.mapError(error, entityName: 'Expense'),
      );
    }
  }

  @override
  Future<Result<Expense>> getExpenseById(String id) async {
    try {
      final row = await _client
          .from(ExpenseSupabaseDto.tableName)
          .select()
          .eq('expense_id', id)
          .maybeSingle();

      if (row == null) {
        return Err<Expense>(
          NotFoundFailure(
            entityName: 'Expense',
            entityId: id,
            message: 'Expense $id was not found.',
          ),
        );
      }
      return Ok<Expense>(ExpenseSupabaseDto.fromSupabase(row));
    } catch (error) {
      return Err<Expense>(
        SupabaseHelpers.mapError(error, entityName: 'Expense', entityId: id),
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
      var query = _client.from(ExpenseSupabaseDto.tableName).select();
      if (employeeId != null) {
        query = query.eq('employee_id', employeeId);
      }
      if (expenseType != null) {
        query = query.eq('expense_type', expenseType.trim());
      }
      if (dateRange?.startDate != null) {
        query = query.gte(
          'date',
          SupabaseHelpers.formatDateOnly(dateRange!.startDate!),
        );
      }
      if (dateRange?.endDate != null) {
        query = query.lte(
          'date',
          SupabaseHelpers.formatDateOnly(dateRange!.endDate!),
        );
      }

      final rows = await query
          .order('date', ascending: false)
          .order('created_at', ascending: false);

      return Ok<List<Expense>>(
        rows.map(ExpenseSupabaseDto.fromSupabase).toList(growable: false),
      );
    } catch (error) {
      return Err<List<Expense>>(
        SupabaseHelpers.mapError(error, entityName: 'Expense'),
      );
    }
  }

  @override
  Stream<List<Expense>> watchExpenses({
    String? employeeId,
    String? expenseType,
  }) {
    final base = _client
        .from(ExpenseSupabaseDto.tableName)
        .stream(primaryKey: const <String>['expense_id']);

    final filtered = employeeId != null
        ? base.eq('employee_id', employeeId)
        : (expenseType != null
            ? base.eq('expense_type', expenseType.trim())
            : base);

    return filtered.order('date', ascending: false).map((rows) {
      var items = rows.map(ExpenseSupabaseDto.fromSupabase);
      if (employeeId != null && expenseType != null) {
        final targetType = expenseType.trim();
        items = items.where((expense) => expense.expenseType == targetType);
      }
      return items.toList(growable: false);
    });
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
      final row = await _client
          .from(ExpenseSupabaseDto.tableName)
          .update(ExpenseSupabaseDto.toUpdateMap(expense))
          .eq('expense_id', expense.id)
          .select()
          .maybeSingle();

      if (row == null) {
        return Err<Expense>(
          NotFoundFailure(
            entityName: 'Expense',
            entityId: expense.id,
            message: 'Expense ${expense.id} was not found.',
          ),
        );
      }

      final updated = ExpenseSupabaseDto.fromSupabase(row);
      await SupabaseAuditRepository.tryRecordAudit(
        _client,
        actorEmployeeId: actorEmployeeId,
        action: AuditAction.updated,
        entityType: AuditEntityType.expense,
        entityId: updated.id,
        description: 'Updated expense ${updated.expenseType}.',
      );
      return Ok<Expense>(updated);
    } catch (error) {
      return Err<Expense>(
        SupabaseHelpers.mapError(
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
      final existing = await getExpenseById(id);
      if (existing.isErr) return Err<void>(existing.failureOrNull!);

      await _client
          .from(ExpenseSupabaseDto.tableName)
          .delete()
          .eq('expense_id', id);

      await SupabaseAuditRepository.tryRecordAudit(
        _client,
        actorEmployeeId: actorEmployeeId,
        action: AuditAction.deleted,
        entityType: AuditEntityType.expense,
        entityId: id,
        description:
            'Deleted expense ${existing.valueOrNull?.expenseType ?? id}.',
      );
      return const Ok<void>(null);
    } catch (error) {
      return Err<void>(
        SupabaseHelpers.mapError(error, entityName: 'Expense', entityId: id),
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
      final raw = await _client.rpc<Map<String, dynamic>>(
        'rpc_get_financial_summary',
        params: <String, dynamic>{
          'p_start_date': dateRange?.startDate == null
              ? null
              : SupabaseHelpers.formatDateOnly(dateRange!.startDate!),
          'p_end_date': dateRange?.endDate == null
              ? null
              : SupabaseHelpers.formatDateOnly(dateRange!.endDate!),
        },
      );
      return Ok<FinancialSummary>(ExpenseSupabaseDto.summaryFromRpc(raw));
    } catch (error) {
      return Err<FinancialSummary>(
        SupabaseHelpers.mapError(error, entityName: 'FinancialSummary'),
      );
    }
  }
}
