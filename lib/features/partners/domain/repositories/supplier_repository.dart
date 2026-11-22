import '../../../../core/result/result.dart';
import '../entities/supplier.dart';

/// Manages abaca fiber suppliers (`suppliers` table / `suppliers` collection).
abstract interface class SupplierRepository {
  /// Creates a new supplier and logs a `created` audit event.
  Future<Result<Supplier>> createSupplier({
    required String firstName,
    String? middleName,
    required String lastName,
    String? contactNumber,
    String? address,
    String? actorEmployeeId,
  });

  /// Fetches a supplier by [id], returning `NotFoundFailure` if absent.
  Future<Result<Supplier>> getSupplierById(String id);

  /// Queries suppliers optionally filtered by [isActive] and [searchQuery].
  ///
  /// Supabase uses `ILIKE`; Firestore uses `search_tokens` `arrayContains` +
  /// client-side substring refinement when needed.
  Future<Result<List<Supplier>>> getSuppliers({
    bool? isActive,
    String? searchQuery,
  });

  /// Streams suppliers optionally filtered by [isActive].
  Stream<List<Supplier>> watchSuppliers({bool? isActive});

  /// Updates supplier fields and syncs denormalized `supplier_name` in Firestore.
  Future<Result<Supplier>> updateSupplier(
    Supplier supplier, {
    String? actorEmployeeId,
  });

  /// Archives (`isActive: false`) or restores (`isActive: true`) a supplier.
  Future<Result<Supplier>> setSupplierActive({
    required String id,
    required bool isActive,
    String? actorEmployeeId,
  });

  /// Deletes a supplier only when unreferenced by `stock_ins`
  /// (`ON DELETE RESTRICT` -> `ConflictFailure` if referenced).
  Future<Result<void>> deleteSupplier(
    String id, {
    String? actorEmployeeId,
  });
}
