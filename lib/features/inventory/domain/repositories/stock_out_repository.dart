import '../../../../core/result/result.dart';
import '../../../../core/types/query_filters.dart';
import '../entities/stock_out.dart';
import '../entities/stock_out_reason.dart';

/// Manages outbound fiber deductions (`stock_outs` table / root collection).
abstract interface class StockOutRepository {
  /// Atomically verifies `inventory.current_stock_kg >= quantityKg`, deducts
  /// stock, records the manual [StockOut], and writes an audit entry.
  ///
  /// Rejects `StockOutReason.released` unless created via
  /// `DeliveryRepository.completeDelivery` so delivery releases cannot be
  /// fabricated or double-deducted.
  Future<Result<StockOut>> createStockOut({
    required String inventoryId,
    required String employeeId,
    required double quantityKg,
    required StockOutReason reason,
    String? notes,
    required DateTime date,
  });

  /// Fetches a single [StockOut] record by [id].
  Future<Result<StockOut>> getStockOutById(String id);

  /// Queries outbound stock movements with optional filters.
  Future<Result<List<StockOut>>> getStockOuts({
    String? inventoryId,
    StockOutReason? reason,
    String? orderId,
    DateRangeFilter? dateRange,
  });

  /// Streams outbound stock movements optionally filtered by grade or reason.
  Stream<List<StockOut>> watchStockOuts({
    String? inventoryId,
    StockOutReason? reason,
  });

  /// Restores [StockOut.quantityKg] back into `inventory` and deletes the entry.
  ///
  /// Rejects delivery-linked stock-outs (`deliveryId != null`) with
  /// `InvalidStateTransitionFailure` so completed delivery deductions remain intact.
  Future<Result<void>> deleteStockOut(
    String id, {
    String? actorEmployeeId,
  });
}
