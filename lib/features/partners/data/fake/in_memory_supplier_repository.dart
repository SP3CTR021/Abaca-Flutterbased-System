import '../../../../core/data/fake/in_memory_database.dart';
import '../../../../core/data/input_validators.dart';
import '../../../../core/errors/app_failure.dart';
import '../../../../core/result/result.dart';
import '../../../audit/domain/entities/audit_enums.dart';
import '../../domain/entities/supplier.dart';
import '../../domain/repositories/supplier_repository.dart';

/// Pure-Dart in-memory implementation of [SupplierRepository].
final class InMemorySupplierRepository implements SupplierRepository {
  InMemorySupplierRepository(this._db);

  final InMemoryDatabase _db;

  @override
  Future<Result<Supplier>> createSupplier({
    required String firstName,
    String? middleName,
    required String lastName,
    String? contactNumber,
    String? address,
    String? actorEmployeeId,
  }) async {
    final errors = <String, String>{};
    InputValidators.requireNonEmpty(errors, 'firstName', firstName);
    InputValidators.requireNonEmpty(errors, 'lastName', lastName);
    InputValidators.validateMaxLength(errors, 'address', address, 500);
    final validation = InputValidators.toFailure(errors);
    if (validation != null) return Err<Supplier>(validation);

    final now = _db.nextTimestamp();
    final created = Supplier(
      id: _db.nextId(),
      firstName: firstName.trim(),
      middleName: _trimOrNull(middleName),
      lastName: lastName.trim(),
      contactNumber: _trimOrNull(contactNumber),
      address: _trimOrNull(address),
      isActive: true,
      createdAt: now,
      updatedAt: now,
    );

    _db.suppliers[created.id] = created;
    _db.recordAudit(
      actorEmployeeId: actorEmployeeId,
      action: AuditAction.created,
      entityType: AuditEntityType.supplier,
      entityId: created.id,
      description: 'Created supplier ${created.fullName}.',
      createdAt: now,
    );
    _db.notify();
    return Ok<Supplier>(created);
  }

  @override
  Future<Result<Supplier>> getSupplierById(String id) async {
    final supplier = _db.suppliers[id];
    if (supplier == null) {
      return Err<Supplier>(
        NotFoundFailure(
          entityName: 'Supplier',
          entityId: id,
          message: 'Supplier $id was not found.',
        ),
      );
    }
    return Ok<Supplier>(supplier);
  }

  @override
  Future<Result<List<Supplier>>> getSuppliers({
    bool? isActive,
    String? searchQuery,
  }) async =>
      Ok<List<Supplier>>(
        _filterSuppliers(isActive: isActive, searchQuery: searchQuery),
      );

  @override
  Stream<List<Supplier>> watchSuppliers({bool? isActive}) =>
      _db.watch(() => _filterSuppliers(isActive: isActive));

  @override
  Future<Result<Supplier>> updateSupplier(
    Supplier supplier, {
    String? actorEmployeeId,
  }) async {
    final errors = <String, String>{};
    InputValidators.requireNonEmpty(errors, 'firstName', supplier.firstName);
    InputValidators.requireNonEmpty(errors, 'lastName', supplier.lastName);
    InputValidators.validateMaxLength(
      errors,
      'address',
      supplier.address,
      500,
    );
    final validation = InputValidators.toFailure(errors);
    if (validation != null) return Err<Supplier>(validation);

    final existing = _db.suppliers[supplier.id];
    if (existing == null) {
      return Err<Supplier>(
        NotFoundFailure(
          entityName: 'Supplier',
          entityId: supplier.id,
          message: 'Supplier ${supplier.id} was not found.',
        ),
      );
    }

    final now = _db.nextTimestamp();
    final trimmedMiddle = _trimOrNull(supplier.middleName);
    final trimmedContact = _trimOrNull(supplier.contactNumber);
    final trimmedAddress = _trimOrNull(supplier.address);
    final updated = supplier.copyWith(
      firstName: supplier.firstName.trim(),
      middleName: trimmedMiddle,
      clearMiddleName: trimmedMiddle == null,
      lastName: supplier.lastName.trim(),
      contactNumber: trimmedContact,
      clearContactNumber: trimmedContact == null,
      address: trimmedAddress,
      clearAddress: trimmedAddress == null,
      createdAt: existing.createdAt,
      updatedAt: now,
    );

    _db.suppliers[updated.id] = updated;
    _db.recordAudit(
      actorEmployeeId: actorEmployeeId,
      action: AuditAction.updated,
      entityType: AuditEntityType.supplier,
      entityId: updated.id,
      description: 'Updated supplier ${updated.fullName}.',
      createdAt: now,
    );
    _db.notify();
    return Ok<Supplier>(updated);
  }

  @override
  Future<Result<Supplier>> setSupplierActive({
    required String id,
    required bool isActive,
    String? actorEmployeeId,
  }) async {
    final existing = _db.suppliers[id];
    if (existing == null) {
      return Err<Supplier>(
        NotFoundFailure(
          entityName: 'Supplier',
          entityId: id,
          message: 'Supplier $id was not found.',
        ),
      );
    }

    final now = _db.nextTimestamp();
    final updated = existing.copyWith(isActive: isActive, updatedAt: now);
    _db.suppliers[id] = updated;
    _db.recordAudit(
      actorEmployeeId: actorEmployeeId,
      action: isActive ? AuditAction.restored : AuditAction.archived,
      entityType: AuditEntityType.supplier,
      entityId: id,
      description: isActive
          ? 'Restored supplier ${updated.fullName}.'
          : 'Archived supplier ${updated.fullName}.',
      createdAt: now,
    );
    _db.notify();
    return Ok<Supplier>(updated);
  }

  @override
  Future<Result<void>> deleteSupplier(
    String id, {
    String? actorEmployeeId,
  }) async {
    final existing = _db.suppliers[id];
    if (existing == null) {
      return Err<void>(
        NotFoundFailure(
          entityName: 'Supplier',
          entityId: id,
          message: 'Supplier $id was not found.',
        ),
      );
    }

    final hasReceipts = _db.stockIns.values.any((s) => s.supplierId == id);
    if (hasReceipts) {
      return const Err<void>(
        ConflictFailure(
          message:
              'Cannot delete supplier with existing stock-in receipts. Archive instead.',
          code: 'foreign_key_violation',
        ),
      );
    }

    _db.suppliers.remove(id);
    _db.recordAudit(
      actorEmployeeId: actorEmployeeId,
      action: AuditAction.deleted,
      entityType: AuditEntityType.supplier,
      entityId: id,
      description: 'Deleted supplier ${existing.fullName}.',
    );
    _db.notify();
    return const Ok<void>(null);
  }

  List<Supplier> _filterSuppliers({bool? isActive, String? searchQuery}) {
    final needle = searchQuery?.trim().toLowerCase() ?? '';
    final list = _db.suppliers.values.where((supplier) {
      if (isActive != null && supplier.isActive != isActive) return false;
      if (needle.isNotEmpty) {
        final matched = supplier.fullName.toLowerCase().contains(needle) ||
            (supplier.contactNumber?.toLowerCase().contains(needle) ?? false) ||
            (supplier.address?.toLowerCase().contains(needle) ?? false);
        if (!matched) return false;
      }
      return true;
    }).toList()
      ..sort((a, b) {
        final lastCmp = a.lastName.compareTo(b.lastName);
        return lastCmp != 0 ? lastCmp : a.firstName.compareTo(b.firstName);
      });
    return List<Supplier>.unmodifiable(list);
  }

  static String? _trimOrNull(String? value) {
    final trimmed = value?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }
}
