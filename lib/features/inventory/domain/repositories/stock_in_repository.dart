import '../../../../core/result/result.dart';
import '../../../../core/types/query_filters.dart';
import '../entities/stock_in.dart';
import '../entities/stock_in_item.dart';

/// Manages inbound fiber receipts (`stock_ins` + `stock_in_items`).
///
/// All writes execute atomically:
/// - Supabase: transactional Postgres RPC (`create_stock_in` / `delete_stock_in`).
/// - Firestore: `runTransaction` updating `stock_ins/{id}`, subcollection
///   `stock_ins/{id}/items/{itemId}`, and `inventory/{inventoryId}.current_stock_kg`.
abstract interface class StockInRepository {
  /// Atomically creates a [StockIn] header, one or more [StockInItem] lines,
  /// increments each target `inventory.current_stock_kg`, and logs an audit entry.
  Future<Result<StockInWithDetails>> createStockIn({
    String? orderId,
    required String supplierId,
    required String employeeId,
    required DateTime dateReceived,
    String? notes,
    required List<NewStockInItemInput> items,
  });

  /// Fetches a [StockIn] header together with its [StockInItem] lines and labels.
  Future<Result<StockInWithDetails>> getStockInWithItems(String id);

  /// Lists stock-in receipts filtered by [supplierId], [orderId], [inventoryId],
  /// and/or [dateRange].
  ///
  /// Firestore uses `collectionGroup('items')` when [inventoryId] is specified.
  Future<Result<List<StockInWithDetails>>> getStockIns({
    String? supplierId,
    String? orderId,
    String? inventoryId,
    DateRangeFilter? dateRange,
  });

  /// Real-time stream of stock-in receipts and their line items.
  Stream<List<StockInWithDetails>> watchStockIns({
    String? supplierId,
    String? orderId,
  });

  /// Atomically reverses every line item's `quantityKg` from `inventory`,
  /// rejecting with `InsufficientStockFailure` if reversing would make stock
  /// negative, then deletes the `stock_ins` receipt (`CASCADE` on line items).
  Future<Result<void>> deleteStockIn(
    String id, {
    String? actorEmployeeId,
  });
}
