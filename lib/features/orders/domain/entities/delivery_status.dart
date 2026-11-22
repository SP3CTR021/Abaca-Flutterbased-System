/// Fulfillment status for an order dispatch (`deliveries.status`).
enum DeliveryStatus {
  pending('pending'),
  delivered('delivered');

  const DeliveryStatus(this.dbValue);

  final String dbValue;

  /// Parses [raw] case-insensitively, throwing [FormatException] if unknown.
  static DeliveryStatus fromDb(String raw) {
    final parsed = tryFromDb(raw);
    if (parsed == null) {
      throw FormatException('Unknown DeliveryStatus value: "$raw"');
    }
    return parsed;
  }

  /// Parses [raw] or returns `null` when unrecognized.
  static DeliveryStatus? tryFromDb(String raw) {
    final normalized = raw.trim().toLowerCase();
    for (final status in DeliveryStatus.values) {
      if (status.dbValue == normalized || status.name.toLowerCase() == normalized) {
        return status;
      }
    }
    return null;
  }
}
