import '../../../../core/data/fake/in_memory_database.dart';
import '../../../../core/data/input_validators.dart';
import '../../../../core/errors/app_failure.dart';
import '../../../../core/result/result.dart';
import '../../../../core/types/query_filters.dart';
import '../../../../core/utils/decimal_precision.dart';
import '../../../audit/domain/entities/audit_enums.dart';
import '../../domain/entities/stock_in.dart';
import '../../domain/entities/stock_in_item.dart';
import '../../domain/repositories/stock_in_repository.dart';

/// Pure-Dart in-memory implementation of [StockInRepository].
final class InMemoryStockInRepository implements StockInRepository {
  InMemoryStockInRepository(this._db);

  final InMemoryDatabase _db;

  @override
  Future<Result<StockInWithDetails>> createStockIn({
    String? orderId,
    required String supplierId,
    required String employeeId,
    required DateTime dateReceived,
    String? notes,
    required List<NewStockInItemInput> items,
  }) async {
    final errors = <String, String>{};
    InputValidators.requireNonEmpty(errors, 'supplierId', supplierId);
    InputValidators.requireNonEmpty(errors, 'employeeId', employeeId);
    if (items.isEmpty) {
      errors['items'] = 'At least one stock-in item is required.';
    } else {
      for (var i = 0; i < items.length; i++) {
        InputValidators.requireNonEmpty(
          errors,
          'items[$i].inventoryId',
          items[i].inventoryId,
        );
        InputValidators.requirePositive(
          errors,
          'items[$i].quantityKg',
          items[i].quantityKg,
        );
        InputValidators.requireNonNegative(
          errors,
          'items[$i].costPerKg',
          items[i].costPerKg,
        );
      }
    }
    final validation = InputValidators.toFailure(errors);
    if (validation != null) return Err<StockInWithDetails>(validation);

    if (!_db.suppliers.containsKey(supplierId)) {
      return Err<StockInWithDetails>(
        NotFoundFailure(
          entityName: 'Supplier',
          entityId: supplierId,
          message: 'Supplier $supplierId was not found.',
        ),
      );
    }
    if (!_db.employees.containsKey(employeeId)) {
      return Err<StockInWithDetails>(
        NotFoundFailure(
          entityName: 'Employee',
          entityId: employeeId,
          message: 'Employee $employeeId was not found.',
        ),
      );
    }
    if (orderId != null && !_db.orders.containsKey(orderId)) {
      return Err<StockInWithDetails>(
        NotFoundFailure(
          entityName: 'Order',
          entityId: orderId,
          message: 'Order $orderId was not found.',
        ),
      );
    }

    for (final input in items) {
      if (!_db.inventory.containsKey(input.inventoryId)) {
        return Err<StockInWithDetails>(
          NotFoundFailure(
            entityName: 'Inventory',
            entityId: input.inventoryId,
            message: 'Inventory grade ${input.inventoryId} was not found.',
          ),
        );
      }
    }

    final now = _db.nextTimestamp();
    final dateOnly =
        DateTime(dateReceived.year, dateReceived.month, dateReceived.day);
    final stockInId = _db.nextId();
    final trimmedNotes = notes?.trim();
    final header = StockIn(
      id: stockInId,
      orderId: orderId,
      supplierId: supplierId,
      employeeId: employeeId,
      dateReceived: dateOnly,
      notes:
          (trimmedNotes == null || trimmedNotes.isEmpty) ? null : trimmedNotes,
      createdAt: now,
      updatedAt: now,
    );

    final createdItems = <StockInItem>[];
    for (final input in items) {
      final qty = DecimalPrecision.round2(input.quantityKg);
      final cost = DecimalPrecision.round2(input.costPerKg);
      createdItems.add(
        StockInItem(
          id: _db.nextId(),
          stockInId: stockInId,
          inventoryId: input.inventoryId,
          quantityKg: qty,
          costPerKg: cost,
          createdAt: now,
          updatedAt: now,
        ),
      );
      final currentInv = _db.inventory[input.inventoryId]!;
      _db.inventory[input.inventoryId] = currentInv.copyWith(
        currentStockKg: DecimalPrecision.add2(currentInv.currentStockKg, qty),
        lastUpdated: now,
      );
    }

    _db.stockIns[stockInId] = header;
    _db.stockInItemsByStockInId[stockInId] = createdItems;
    _db.recordAudit(
      actorEmployeeId: employeeId,
      action: AuditAction.created,
      entityType: AuditEntityType.stockIn,
      entityId: stockInId,
      description:
          'Recorded stock-in receipt with ${createdItems.length} item(s).',
      createdAt: now,
    );
    _db.notify();
    return Ok<StockInWithDetails>(_hydrate(header));
  }

  @override
  Future<Result<StockInWithDetails>> getStockInWithItems(String id) async {
    final header = _db.stockIns[id];
    if (header == null) {
      return Err<StockInWithDetails>(
        NotFoundFailure(
          entityName: 'StockIn',
          entityId: id,
          message: 'Stock-in receipt $id was not found.',
        ),
      );
    }
    return Ok<StockInWithDetails>(_hydrate(header));
  }

  @override
  Future<Result<List<StockInWithDetails>>> getStockIns({
    String? supplierId,
    String? orderId,
    String? inventoryId,
    DateRangeFilter? dateRange,
  }) async {
    final rangeFailure = InputValidators.validateDateRange(dateRange);
    if (rangeFailure != null) return Err<List<StockInWithDetails>>(rangeFailure);

    final list = _filterHeaders(
      supplierId: supplierId,
      orderId: orderId,
      inventoryId: inventoryId,
      dateRange: dateRange,
    ).map(_hydrate).toList(growable: false);
    return Ok<List<StockInWithDetails>>(List<StockInWithDetails>.unmodifiable(list));
  }

  @override
  Stream<List<StockInWithDetails>> watchStockIns({
    String? supplierId,
    String? orderId,
  }) =>
      _db.watch(
        () => _filterHeaders(supplierId: supplierId, orderId: orderId)
            .map(_hydrate)
            .toList(growable: false),
      );

  @override
  Future<Result<void>> deleteStockIn(
    String id, {
    String? actorEmployeeId,
  }) async {
    final header = _db.stockIns[id];
    if (header == null) {
      return Err<void>(
        NotFoundFailure(
          entityName: 'StockIn',
          entityId: id,
          message: 'Stock-in receipt $id was not found.',
        ),
      );
    }

    final items = _db.stockInItemsByStockInId[id] ?? const <StockInItem>[];
    final reversals = <String, double>{};
    for (final item in items) {
      reversals[item.inventoryId] = DecimalPrecision.add2(
        reversals[item.inventoryId] ?? 0.0,
        item.quantityKg,
      );
    }

    // Validate before reversing any inventory grade.
    for (final entry in reversals.entries) {
      final inv = _db.inventory[entry.key]!;
      if (DecimalPrecision.compare2(inv.currentStockKg, entry.value) < 0) {
        return Err<void>(
          InsufficientStockFailure(
            abacaType: inv.abacaType,
            availableKg: inv.currentStockKg,
            requestedKg: entry.value,
            message:
                'Cannot reverse stock-in: insufficient ${inv.abacaType} stock.',
          ),
        );
      }
    }

    final now = _db.nextTimestamp();
    for (final entry in reversals.entries) {
      final inv = _db.inventory[entry.key]!;
      _db.inventory[entry.key] = inv.copyWith(
        currentStockKg:
            DecimalPrecision.subtract2(inv.currentStockKg, entry.value),
        lastUpdated: now,
      );
    }

    _db.stockInItemsByStockInId.remove(id);
    _db.stockIns.remove(id);
    _db.recordAudit(
      actorEmployeeId: actorEmployeeId,
      action: AuditAction.deleted,
      entityType: AuditEntityType.stockIn,
      entityId: id,
      description:
          'Deleted stock-in receipt and reversed inbound stock quantities.',
      createdAt: now,
    );
    _db.notify();
    return const Ok<void>(null);
  }

  List<StockIn> _filterHeaders({
    String? supplierId,
    String? orderId,
    String? inventoryId,
    DateRangeFilter? dateRange,
  }) {
    final headers = _db.stockIns.values.where((header) {
      if (supplierId != null && header.supplierId != supplierId) return false;
      if (orderId != null && header.orderId != orderId) return false;
      if (dateRange != null && !dateRange.contains(header.dateReceived)) {
        return false;
      }
      if (inventoryId != null) {
        final items =
            _db.stockInItemsByStockInId[header.id] ?? const <StockInItem>[];
        if (!items.any((item) => item.inventoryId == inventoryId)) return false;
      }
      return true;
    }).toList()
      ..sort((a, b) {
        final dateCmp = b.dateReceived.compareTo(a.dateReceived);
        return dateCmp != 0 ? dateCmp : b.createdAt.compareTo(a.createdAt);
      });
    return headers;
  }

  StockInWithDetails _hydrate(StockIn header) {
    final items =
        _db.stockInItemsByStockInId[header.id] ?? const <StockInItem>[];
    final abacaTypes = <String, String>{};
    for (final item in items) {
      final inv = _db.inventory[item.inventoryId];
      if (inv != null) {
        abacaTypes[item.inventoryId] = inv.abacaType;
      }
    }
    return StockInWithDetails(
      stockIn: header,
      items: items,
      supplierName: _db.suppliers[header.supplierId]?.fullName,
      employeeName: _db.employees[header.employeeId]?.fullName,
      abacaTypeByInventoryId: abacaTypes,
    );
  }
}
