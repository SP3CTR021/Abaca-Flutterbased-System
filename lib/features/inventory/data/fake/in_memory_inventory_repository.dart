import '../../../../core/data/fake/in_memory_database.dart';
import '../../../../core/data/input_validators.dart';
import '../../../../core/errors/app_failure.dart';
import '../../../../core/result/result.dart';
import '../../../../core/utils/decimal_precision.dart';
import '../../../audit/domain/entities/audit_enums.dart';
import '../../domain/entities/inventory.dart';
import '../../domain/repositories/inventory_repository.dart';

/// Pure-Dart in-memory implementation of [InventoryRepository].
final class InMemoryInventoryRepository implements InventoryRepository {
  InMemoryInventoryRepository(this._db);

  final InMemoryDatabase _db;

  @override
  Future<Result<Inventory>> createGrade({
    required String abacaType,
    String? description,
    double initialStockKg = 0.0,
    double minStockThresholdKg = 0.0,
    String? actorEmployeeId,
  }) async {
    final errors = <String, String>{};
    InputValidators.requireNonEmpty(errors, 'abacaType', abacaType);
    InputValidators.validateMaxLength(
      errors,
      'description',
      description,
      500,
    );
    InputValidators.requireNonNegative(
      errors,
      'initialStockKg',
      initialStockKg,
    );
    InputValidators.requireNonNegative(
      errors,
      'minStockThresholdKg',
      minStockThresholdKg,
    );
    final validation = InputValidators.toFailure(errors);
    if (validation != null) return Err<Inventory>(validation);

    final trimmedType = abacaType.trim();
    final duplicate = _db.inventory.values.any(
      (inv) => inv.abacaType.toLowerCase() == trimmedType.toLowerCase(),
    );
    if (duplicate) {
      return Err<Inventory>(
        ConflictFailure(
          message: 'Abaca grade "$trimmedType" already exists.',
          code: 'unique_violation',
        ),
      );
    }

    final now = _db.nextTimestamp();
    final trimmedDesc = description?.trim();
    final created = Inventory(
      id: _db.nextId(),
      abacaType: trimmedType,
      description:
          (trimmedDesc == null || trimmedDesc.isEmpty) ? null : trimmedDesc,
      currentStockKg: DecimalPrecision.round2(initialStockKg),
      minStockThresholdKg: DecimalPrecision.round2(minStockThresholdKg),
      isActive: true,
      createdAt: now,
      lastUpdated: now,
    );

    _db.inventory[created.id] = created;
    _db.recordAudit(
      actorEmployeeId: actorEmployeeId,
      action: AuditAction.created,
      entityType: AuditEntityType.inventory,
      entityId: created.id,
      description: 'Created inventory grade ${created.abacaType}.',
      newValues: <String, Object?>{
        'abaca_type': created.abacaType,
        'current_stock_kg': created.currentStockKg,
        'min_stock_threshold_kg': created.minStockThresholdKg,
      },
      createdAt: now,
    );
    _db.notify();
    return Ok<Inventory>(created);
  }

  @override
  Future<Result<Inventory>> getInventoryById(String id) async {
    final inv = _db.inventory[id];
    if (inv == null) {
      return Err<Inventory>(
        NotFoundFailure(
          entityName: 'Inventory',
          entityId: id,
          message: 'Inventory grade $id was not found.',
        ),
      );
    }
    return Ok<Inventory>(inv);
  }

  @override
  Future<Result<Inventory>> getInventoryByAbacaType(String abacaType) async {
    final trimmed = abacaType.trim();
    if (trimmed.isEmpty) {
      return Err<Inventory>(
        ValidationFailure(
          message: 'Abaca type is required.',
          fieldErrors: const <String, String>{
            'abacaType': 'abacaType is required.',
          },
        ),
      );
    }

    for (final inv in _db.inventory.values) {
      if (inv.abacaType.toLowerCase() == trimmed.toLowerCase()) {
        return Ok<Inventory>(inv);
      }
    }
    return Err<Inventory>(
      NotFoundFailure(
        entityName: 'Inventory',
        entityId: trimmed,
        message: 'Inventory grade "$trimmed" was not found.',
      ),
    );
  }

  @override
  Future<Result<List<Inventory>>> getAllInventory({
    bool? isActive,
    bool onlyLowStock = false,
  }) async =>
      Ok<List<Inventory>>(
        _filterInventory(isActive: isActive, onlyLowStock: onlyLowStock),
      );

  @override
  Stream<List<Inventory>> watchInventory({
    bool? isActive,
    bool onlyLowStock = false,
  }) =>
      _db.watch(
        () => _filterInventory(isActive: isActive, onlyLowStock: onlyLowStock),
      );

  @override
  Future<Result<Inventory>> updateGradeMetadata({
    required String id,
    String? abacaType,
    String? description,
    bool clearDescription = false,
    double? minStockThresholdKg,
    bool? isActive,
    String? actorEmployeeId,
  }) async {
    final errors = <String, String>{};
    if (abacaType != null) {
      InputValidators.requireNonEmpty(errors, 'abacaType', abacaType);
    }
    InputValidators.validateMaxLength(
      errors,
      'description',
      description,
      500,
    );
    if (minStockThresholdKg != null) {
      InputValidators.requireNonNegative(
        errors,
        'minStockThresholdKg',
        minStockThresholdKg,
      );
    }
    final validation = InputValidators.toFailure(errors);
    if (validation != null) return Err<Inventory>(validation);

    final existing = _db.inventory[id];
    if (existing == null) {
      return Err<Inventory>(
        NotFoundFailure(
          entityName: 'Inventory',
          entityId: id,
          message: 'Inventory grade $id was not found.',
        ),
      );
    }

    final nextType = abacaType?.trim() ?? existing.abacaType;
    final duplicate = _db.inventory.values.any(
      (other) =>
          other.id != id &&
          other.abacaType.toLowerCase() == nextType.toLowerCase(),
    );
    if (duplicate) {
      return Err<Inventory>(
        ConflictFailure(
          message: 'Abaca grade "$nextType" already exists.',
          code: 'unique_violation',
        ),
      );
    }

    final now = _db.nextTimestamp();
    final nextDesc = clearDescription
        ? null
        : (description != null
            ? (description.trim().isEmpty ? null : description.trim())
            : existing.description);

    final updated = existing.copyWith(
      abacaType: nextType,
      description: nextDesc,
      clearDescription: nextDesc == null,
      minStockThresholdKg: minStockThresholdKg != null
          ? DecimalPrecision.round2(minStockThresholdKg)
          : existing.minStockThresholdKg,
      isActive: isActive ?? existing.isActive,
      lastUpdated: now,
    );

    _db.inventory[id] = updated;

    // Mirror ON UPDATE CASCADE on orders.(inventory_id, abaca_type).
    if (updated.abacaType != existing.abacaType) {
      for (final entry in _db.orders.entries.toList(growable: false)) {
        if (entry.value.inventoryId == id) {
          _db.orders[entry.key] =
              entry.value.copyWith(abacaType: updated.abacaType);
        }
      }
    }

    _db.recordAudit(
      actorEmployeeId: actorEmployeeId,
      action: AuditAction.updated,
      entityType: AuditEntityType.inventory,
      entityId: id,
      description: 'Updated inventory grade ${updated.abacaType}.',
      createdAt: now,
    );
    _db.notify();
    return Ok<Inventory>(updated);
  }

  @override
  Future<Result<void>> deleteGrade(
    String id, {
    String? actorEmployeeId,
  }) async {
    final existing = _db.inventory[id];
    if (existing == null) {
      return Err<void>(
        NotFoundFailure(
          entityName: 'Inventory',
          entityId: id,
          message: 'Inventory grade $id was not found.',
        ),
      );
    }

    final referenced = _db.orders.values.any((o) => o.inventoryId == id) ||
        _db.stockOuts.values.any((so) => so.inventoryId == id) ||
        _db.stockInItemsByStockInId.values
            .expand((items) => items)
            .any((item) => item.inventoryId == id);
    if (referenced) {
      return const Err<void>(
        ConflictFailure(
          message:
              'Cannot delete abaca grade referenced by orders or stock history. Archive instead.',
          code: 'foreign_key_violation',
        ),
      );
    }

    _db.inventory.remove(id);
    _db.recordAudit(
      actorEmployeeId: actorEmployeeId,
      action: AuditAction.deleted,
      entityType: AuditEntityType.inventory,
      entityId: id,
      description: 'Deleted inventory grade ${existing.abacaType}.',
    );
    _db.notify();
    return const Ok<void>(null);
  }

  List<Inventory> _filterInventory({
    bool? isActive,
    required bool onlyLowStock,
  }) {
    final list = _db.inventory.values.where((item) {
      if (isActive != null && item.isActive != isActive) return false;
      if (onlyLowStock && !item.isLowStock) return false;
      return true;
    }).toList()
      ..sort((a, b) => a.abacaType.compareTo(b.abacaType));
    return List<Inventory>.unmodifiable(list);
  }
}
