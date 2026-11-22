/// Categorized reason for outbound inventory deductions (`stock_outs.reason`).
enum StockOutReason {
  /// Stock released to fulfill a customer delivery.
  released('released'),
  damaged('damaged'),
  discarded('discarded'),
  lost('lost');

  const StockOutReason(this.dbValue);

  /// Canonical lowercase value persisted in Postgres and Firestore.
  final String dbValue;

  /// Parses [raw] case-insensitively, throwing [FormatException] if unknown.
  static StockOutReason fromDb(String raw) {
    final parsed = tryFromDb(raw);
    if (parsed == null) {
      throw FormatException('Unknown StockOutReason value: "$raw"');
    }
    return parsed;
  }

  /// Parses [raw] or returns `null` when unrecognized.
  static StockOutReason? tryFromDb(String raw) {
    final normalized = raw.trim().toLowerCase();
    for (final reason in StockOutReason.values) {
      if (reason.dbValue == normalized || reason.name.toLowerCase() == normalized) {
        return reason;
      }
    }
    return null;
  }
}
