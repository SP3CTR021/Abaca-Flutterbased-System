import '../../../../core/data/fake/in_memory_database.dart';
import '../../../../core/data/input_validators.dart';
import '../../../../core/errors/app_failure.dart';
import '../../../../core/result/result.dart';
import '../../../../core/types/query_filters.dart';
import '../../../../core/utils/decimal_precision.dart';
import '../../../audit/domain/entities/audit_enums.dart';
import '../../domain/entities/stock_out.dart';
import '../../domain/entities/stock_out_reason.dart';
import '../../domain/repositories/stock_out_repository.dart';

/// Pure-Dart in-memory implementation of [StockOutRepository].
final class InMemoryStockOutRepository implements StockOutRepository {
  InMemoryStockOutRepository(this._db);

  final InMemoryDatabase _db;

  @override
  Future<Result<StockOut>> createStockOut({
    required String inventoryId,
    required String employeeId,
    required double quantityKg,
    required StockOutReason reason,
    String? notes,
    required DateTime date,
  }) async {
    if (reason == StockOutReason.released) {
      return const Err<StockOut>(
        InvalidStateTransitionFailure(
          entityName: 'StockOut',
          currentState: 'manual',
          attemptedAction: 'create_released_stock_out',
          message:
              'Released stock-outs must be created via DeliveryRepository.completeDelivery.',
        ),
      );
    }

    final errors = <String, String>{};
    InputValidators.requireNonEmpty(errors, 'inventoryId', inventoryId);
    InputValidators.requireNonEmpty(errors, 'employeeId', employeeId);
    InputValidators.requirePositive(errors, 'quantityKg', quantityKg);
    final validation = InputValidators.toFailure(errors);
    if (validation != null) return Err<StockOut>(validation);

    final inv = _db.inventory[inventoryId];
    if (inv == null) {
      return Err<StockOut>(
        NotFoundFailure(
          entityName: 'Inventory',
          entityId: inventoryId,
          message: 'Inventory grade $inventoryId was not found.',
        ),
      );
    }
    if (!_db.employees.containsKey(employeeId)) {
      return Err<StockOut>(
        NotFoundFailure(
          entityName: 'Employee',
          entityId: employeeId,
          message: 'Employee $employeeId was not found.',
        ),
      );
    }

    final qty = DecimalPrecision.round2(quantityKg);
    if (DecimalPrecision.compare2(inv.currentStockKg, qty) < 0) {
      return Err<StockOut>(
        InsufficientStockFailure(
          abacaType: inv.abacaType,
          availableKg: inv.currentStockKg,
          requestedKg: qty,
          message: 'Insufficient ${inv.abacaType} stock for stock-out.',
        ),
      );
    }

    final now = _db.nextTimestamp();
    final dateOnly = DateTime(date.year, date.month, date.day);
    final trimmedNotes = notes?.trim();
    final created = StockOut(
      id: _db.nextId(),
      inventoryId: inventoryId,
      employeeId: employeeId,
      quantityKg: qty,
      reason: reason,
      notes:
          (trimmedNotes == null || trimmedNotes.isEmpty) ? null : trimmedNotes,
      date: dateOnly,
      createdAt: now,
      updatedAt: now,
    );

    _db.inventory[inventoryId] = inv.copyWith(
      currentStockKg: DecimalPrecision.subtract2(inv.currentStockKg, qty),
      lastUpdated: now,
    );
    _db.stockOuts[created.id] = created;
    _db.recordAudit(
      actorEmployeeId: employeeId,
      action: AuditAction.stockAdjusted,
      entityType: AuditEntityType.stockOut,
      entityId: created.id,
      description:
          'Recorded manual stock-out (${reason.dbValue}): $qty kg of ${inv.abacaType}.',
      createdAt: now,
    );
    _db.notify();
    return Ok<StockOut>(created);
  }

  @override
  Future<Result<StockOut>> getStockOutById(String id) async {
    final stockOut = _db.stockOuts[id];
    if (stockOut == null) {
      return Err<StockOut>(
        NotFoundFailure(
          entityName: 'StockOut',
          entityId: id,
          message: 'StockOut $id was not found.',
        ),
      );
    }
    return Ok<StockOut>(stockOut);
  }

  @override
  Future<Result<List<StockOut>>> getStockOuts({
    String? inventoryId,
    StockOutReason? reason,
    String? orderId,
    DateRangeFilter? dateRange,
  }) async {
    final rangeFailure = InputValidators.validateDateRange(dateRange);
    if (rangeFailure != null) return Err<List<StockOut>>(rangeFailure);

    return Ok<List<StockOut>>(
      _filterStockOuts(
        inventoryId: inventoryId,
        reason: reason,
        orderId: orderId,
        dateRange: dateRange,
      ),
    );
  }

  @override
  Stream<List<StockOut>> watchStockOuts({
    String? inventoryId,
    StockOutReason? reason,
  }) =>
      _db.watch(
        () => _filterStockOuts(inventoryId: inventoryId, reason: reason),
      );

  @override
  Future<Result<void>> deleteStockOut(
    String id, {
    String? actorEmployeeId,
  }) async {
    final stockOut = _db.stockOuts[id];
    if (stockOut == null) {
      return Err<void>(
        NotFoundFailure(
          entityName: 'StockOut',
          entityId: id,
          message: 'StockOut $id was not found.',
        ),
      );
    }
    if (stockOut.deliveryId != null) {
      return const Err<void>(
        InvalidStateTransitionFailure(
          entityName: 'StockOut',
          currentState: 'delivery_linked',
          attemptedAction: 'delete_stock_out',
          message: 'Delivery-linked stock-out records cannot be deleted.',
        ),
      );
    }

    final inv = _db.inventory[stockOut.inventoryId]!;
    final now = _db.nextTimestamp();
    _db.inventory[inv.id] = inv.copyWith(
      currentStockKg:
          DecimalPrecision.add2(inv.currentStockKg, stockOut.quantityKg),
      lastUpdated: now,
    );
    _db.stockOuts.remove(id);
    _db.recordAudit(
      actorEmployeeId: actorEmployeeId,
      action: AuditAction.deleted,
      entityType: AuditEntityType.stockOut,
      entityId: id,
      description:
          'Deleted manual stock-out and restored ${stockOut.quantityKg} kg.',
      createdAt: now,
    );
    _db.notify();
    return const Ok<void>(null);
  }

  List<StockOut> _filterStockOuts({
    String? inventoryId,
    StockOutReason? reason,
    String? orderId,
    DateRangeFilter? dateRange,
  }) {
    final list = _db.stockOuts.values.where((entry) {
      if (inventoryId != null && entry.inventoryId != inventoryId) return false;
      if (reason != null && entry.reason != reason) return false;
      if (orderId != null && entry.orderId != orderId) return false;
      if (dateRange != null && !dateRange.contains(entry.date)) return false;
      return true;
    }).toList()
      ..sort((a, b) {
        final dateCmp = b.date.compareTo(a.date);
        return dateCmp != 0 ? dateCmp : b.createdAt.compareTo(a.createdAt);
      });
    return List<StockOut>.unmodifiable(list);
  }
}
