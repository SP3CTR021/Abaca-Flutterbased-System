import '../../../../core/data/fake/in_memory_database.dart';
import '../../../../core/data/input_validators.dart';
import '../../../../core/errors/app_failure.dart';
import '../../../../core/result/result.dart';
import '../../../audit/domain/entities/audit_enums.dart';
import '../../domain/entities/customer.dart';
import '../../domain/repositories/customer_repository.dart';

/// Pure-Dart in-memory implementation of [CustomerRepository].
final class InMemoryCustomerRepository implements CustomerRepository {
  InMemoryCustomerRepository(this._db);

  final InMemoryDatabase _db;

  @override
  Future<Result<Customer>> createCustomer({
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
    if (validation != null) return Err<Customer>(validation);

    final now = _db.nextTimestamp();
    final created = Customer(
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

    _db.customers[created.id] = created;
    _db.recordAudit(
      actorEmployeeId: actorEmployeeId,
      action: AuditAction.created,
      entityType: AuditEntityType.customer,
      entityId: created.id,
      description: 'Created customer ${created.fullName}.',
      createdAt: now,
    );
    _db.notify();
    return Ok<Customer>(created);
  }

  @override
  Future<Result<Customer>> getCustomerById(String id) async {
    final customer = _db.customers[id];
    if (customer == null) {
      return Err<Customer>(
        NotFoundFailure(
          entityName: 'Customer',
          entityId: id,
          message: 'Customer $id was not found.',
        ),
      );
    }
    return Ok<Customer>(customer);
  }

  @override
  Future<Result<List<Customer>>> getCustomers({
    bool? isActive,
    String? searchQuery,
  }) async =>
      Ok<List<Customer>>(
        _filterCustomers(isActive: isActive, searchQuery: searchQuery),
      );

  @override
  Stream<List<Customer>> watchCustomers({bool? isActive}) =>
      _db.watch(() => _filterCustomers(isActive: isActive));

  @override
  Future<Result<Customer>> updateCustomer(
    Customer customer, {
    String? actorEmployeeId,
  }) async {
    final errors = <String, String>{};
    InputValidators.requireNonEmpty(errors, 'firstName', customer.firstName);
    InputValidators.requireNonEmpty(errors, 'lastName', customer.lastName);
    InputValidators.validateMaxLength(
      errors,
      'address',
      customer.address,
      500,
    );
    final validation = InputValidators.toFailure(errors);
    if (validation != null) return Err<Customer>(validation);

    final existing = _db.customers[customer.id];
    if (existing == null) {
      return Err<Customer>(
        NotFoundFailure(
          entityName: 'Customer',
          entityId: customer.id,
          message: 'Customer ${customer.id} was not found.',
        ),
      );
    }

    final now = _db.nextTimestamp();
    final trimmedMiddle = _trimOrNull(customer.middleName);
    final trimmedContact = _trimOrNull(customer.contactNumber);
    final trimmedAddress = _trimOrNull(customer.address);
    final updated = customer.copyWith(
      firstName: customer.firstName.trim(),
      middleName: trimmedMiddle,
      clearMiddleName: trimmedMiddle == null,
      lastName: customer.lastName.trim(),
      contactNumber: trimmedContact,
      clearContactNumber: trimmedContact == null,
      address: trimmedAddress,
      clearAddress: trimmedAddress == null,
      createdAt: existing.createdAt,
      updatedAt: now,
    );

    _db.customers[updated.id] = updated;
    _db.recordAudit(
      actorEmployeeId: actorEmployeeId,
      action: AuditAction.updated,
      entityType: AuditEntityType.customer,
      entityId: updated.id,
      description: 'Updated customer ${updated.fullName}.',
      createdAt: now,
    );
    _db.notify();
    return Ok<Customer>(updated);
  }

  @override
  Future<Result<Customer>> setCustomerActive({
    required String id,
    required bool isActive,
    String? actorEmployeeId,
  }) async {
    final existing = _db.customers[id];
    if (existing == null) {
      return Err<Customer>(
        NotFoundFailure(
          entityName: 'Customer',
          entityId: id,
          message: 'Customer $id was not found.',
        ),
      );
    }

    final now = _db.nextTimestamp();
    final updated = existing.copyWith(isActive: isActive, updatedAt: now);
    _db.customers[id] = updated;
    _db.recordAudit(
      actorEmployeeId: actorEmployeeId,
      action: isActive ? AuditAction.restored : AuditAction.archived,
      entityType: AuditEntityType.customer,
      entityId: id,
      description: isActive
          ? 'Restored customer ${updated.fullName}.'
          : 'Archived customer ${updated.fullName}.',
      createdAt: now,
    );
    _db.notify();
    return Ok<Customer>(updated);
  }

  @override
  Future<Result<void>> deleteCustomer(
    String id, {
    String? actorEmployeeId,
  }) async {
    final existing = _db.customers[id];
    if (existing == null) {
      return Err<void>(
        NotFoundFailure(
          entityName: 'Customer',
          entityId: id,
          message: 'Customer $id was not found.',
        ),
      );
    }

    final hasOrders = _db.orders.values.any((o) => o.customerId == id);
    if (hasOrders) {
      return const Err<void>(
        ConflictFailure(
          message:
              'Cannot delete customer with existing orders. Archive instead.',
          code: 'foreign_key_violation',
        ),
      );
    }

    _db.customers.remove(id);
    _db.recordAudit(
      actorEmployeeId: actorEmployeeId,
      action: AuditAction.deleted,
      entityType: AuditEntityType.customer,
      entityId: id,
      description: 'Deleted customer ${existing.fullName}.',
    );
    _db.notify();
    return const Ok<void>(null);
  }

  List<Customer> _filterCustomers({bool? isActive, String? searchQuery}) {
    final needle = searchQuery?.trim().toLowerCase() ?? '';
    final list = _db.customers.values.where((customer) {
      if (isActive != null && customer.isActive != isActive) return false;
      if (needle.isNotEmpty) {
        final matched = customer.fullName.toLowerCase().contains(needle) ||
            (customer.contactNumber?.toLowerCase().contains(needle) ?? false) ||
            (customer.address?.toLowerCase().contains(needle) ?? false);
        if (!matched) return false;
      }
      return true;
    }).toList()
      ..sort((a, b) {
        final lastCmp = a.lastName.compareTo(b.lastName);
        return lastCmp != 0 ? lastCmp : a.firstName.compareTo(b.firstName);
      });
    return List<Customer>.unmodifiable(list);
  }

  static String? _trimOrNull(String? value) {
    final trimmed = value?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }
}
