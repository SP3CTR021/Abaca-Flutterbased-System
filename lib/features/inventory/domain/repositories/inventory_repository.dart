import '../../../../core/result/result.dart';
import '../entities/inventory.dart';

/// Manages master abaca grade ledgers (`inventory` table / root collection).
///
/// Direct mutation of `currentStockKg` is intentionally omitted here; stock
/// quantities change only through atomic `StockIn`, `StockOut`, and
/// `Delivery.completeDelivery` transactions so the ledger stays auditable.
abstract interface class InventoryRepository {
  /// Creates a new abaca grade ledger row with unique [abacaType].
  ///
  /// Supabase enforces uniqueness via SQL `UNIQUE(abaca_type)`; Firestore
  /// enforces atomicity via `inventory_type_locks/{normalizedType}`.
  Future<Result<Inventory>> createGrade({
    required String abacaType,
    String? description,
    double initialStockKg = 0.0,
    double minStockThresholdKg = 0.0,
    String? actorEmployeeId,
  });

  /// Fetches an [Inventory] grade by primary key [id].
  Future<Result<Inventory>> getInventoryById(String id);

  /// Fetches an [Inventory] grade by its unique [abacaType] label.
  Future<Result<Inventory>> getInventoryByAbacaType(String abacaType);

  /// Lists grades optionally filtered by [isActive] and [onlyLowStock].
  Future<Result<List<Inventory>>> getAllInventory({
    bool? isActive,
    bool onlyLowStock = false,
  });

  /// Real-time stream of inventory ledgers.
  Stream<List<Inventory>> watchInventory({
    bool? isActive,
    bool onlyLowStock = false,
  });

  /// Updates grade metadata ([abacaType], [description], [minStockThresholdKg],
  /// [isActive]) without altering [Inventory.currentStockKg].
  ///
  /// Renaming [abacaType] cascades cleanly via `ON UPDATE CASCADE` in Postgres
  /// and batched updates + lock doc swap in Firestore.
  Future<Result<Inventory>> updateGradeMetadata({
    required String id,
    String? abacaType,
    String? description,
    bool clearDescription = false,
    double? minStockThresholdKg,
    bool? isActive,
    String? actorEmployeeId,
  });

  /// Deletes a grade only if unreferenced (`ON DELETE RESTRICT` ->
  /// `ConflictFailure` if used by `orders`, `stock_in_items`, or `stock_outs`).
  Future<Result<void>> deleteGrade(
    String id, {
    String? actorEmployeeId,
  });
}
