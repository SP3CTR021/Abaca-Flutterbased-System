/// Lifecycle states for customer orders (`orders.status`).
///
/// Valid state transitions:
/// - `pending` -> `stocked` (`markOrderStocked`)
/// - `pending` or `stocked` (only if no completed delivery) -> `cancelled`
/// - `stocked` -> `delivered` (exclusively via `DeliveryRepository.completeDelivery`)
enum OrderStatus {
  pending('pending'),
  stocked('stocked'),
  delivered('delivered'),
  cancelled('cancelled');

  const OrderStatus(this.dbValue);

  final String dbValue;

  /// Parses [raw] case-insensitively, throwing [FormatException] if unknown.
  static OrderStatus fromDb(String raw) {
    final parsed = tryFromDb(raw);
    if (parsed == null) {
      throw FormatException('Unknown OrderStatus value: "$raw"');
    }
    return parsed;
  }

  /// Parses [raw] or returns `null` when unrecognized.
  static OrderStatus? tryFromDb(String raw) {
    final normalized = raw.trim().toLowerCase();
    for (final status in OrderStatus.values) {
      if (status.dbValue == normalized || status.name.toLowerCase() == normalized) {
        return status;
      }
    }
    return null;
  }
}

/// Derived payment progress for an [Order] based on cumulative `payments`.
enum OrderPaymentStatus {
  unpaid('unpaid'),
  partiallyPaid('partially_paid'),
  paid('paid');

  const OrderPaymentStatus(this.dbValue);

  final String dbValue;
}
