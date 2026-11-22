import '../../../../core/result/result.dart';
import '../entities/customer.dart';

/// Manages purchase order customers (`customers` table / `customers` collection).
abstract interface class CustomerRepository {
  /// Creates a new customer and logs a `created` audit event.
  Future<Result<Customer>> createCustomer({
    required String firstName,
    String? middleName,
    required String lastName,
    String? contactNumber,
    String? address,
    String? actorEmployeeId,
  });

  /// Fetches a customer by [id], returning `NotFoundFailure` if absent.
  Future<Result<Customer>> getCustomerById(String id);

  /// Queries customers optionally filtered by [isActive] and [searchQuery].
  ///
  /// Supabase uses `ILIKE`; Firestore uses `search_tokens` `arrayContains` +
  /// client-side substring refinement when needed.
  Future<Result<List<Customer>>> getCustomers({
    bool? isActive,
    String? searchQuery,
  });

  /// Streams customers optionally filtered by [isActive].
  Stream<List<Customer>> watchCustomers({bool? isActive});

  /// Updates customer fields and syncs denormalized `customer_name` in Firestore.
  Future<Result<Customer>> updateCustomer(
    Customer customer, {
    String? actorEmployeeId,
  });

  /// Archives (`isActive: false`) or restores (`isActive: true`) a customer.
  Future<Result<Customer>> setCustomerActive({
    required String id,
    required bool isActive,
    String? actorEmployeeId,
  });

  /// Deletes a customer only when unreferenced by `orders`
  /// (`ON DELETE RESTRICT` -> `ConflictFailure` if referenced).
  Future<Result<void>> deleteCustomer(
    String id, {
    String? actorEmployeeId,
  });
}
