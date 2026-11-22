/// Canonical Cloud Firestore root collection and subcollection names.
abstract final class FirestoreCollections {
  static const String employees = 'employees';
  static const String suppliers = 'suppliers';
  static const String customers = 'customers';
  static const String inventory = 'inventory';

  /// Lock docs keyed by normalized `abaca_type` (`inventory_type_locks/{key}`)
  /// enforcing unique fiber grade names and enabling ID-based lookup inside
  /// `FirebaseFirestore.runTransaction` (which cannot run `.where()` queries).
  static const String inventoryTypeLocks = 'inventory_type_locks';

  static const String orders = 'orders';
  static const String deliveries = 'deliveries';

  /// Lock docs keyed by `order_id` (`order_delivery_locks/{orderId}`)
  /// enforcing strict 1:1 cardinality between `orders` and `deliveries`.
  static const String orderDeliveryLocks = 'order_delivery_locks';

  static const String stockIns = 'stock_ins';

  /// Subcollection under `stock_ins/{stockinId}/items/{stockInItemId}` modeling
  /// attributed M:N line items between receipts and fiber grades.
  static const String stockInItemsSubcollection = 'items';

  static const String stockOuts = 'stock_outs';

  /// Subcollection under `orders/{orderId}/payments/{paymentId}` modeling 1:N
  /// order payments (also queried globally via `collectionGroup('payments')`).
  static const String paymentsSubcollection = 'payments';

  static const String expenses = 'expenses';
  static const String activityLogs = 'activity_logs';

  /// Produces a safe, case-insensitive document ID for lock collections.
  static String normalizeLockKey(String raw) =>
      Uri.encodeComponent(raw.trim().toLowerCase());
}
