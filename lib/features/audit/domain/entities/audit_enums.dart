/// Categorized action types recorded in `activity_logs`.
enum AuditAction {
  created('created'),
  updated('updated'),
  deleted('deleted'),
  archived('archived'),
  restored('restored'),
  statusChanged('status_changed'),
  stockAdjusted('stock_adjusted'),
  deliveryCompleted('delivery_completed'),
  paymentRecorded('payment_recorded'),
  paymentVoided('payment_voided'),
  signedIn('signed_in'),
  signedOut('signed_out');

  const AuditAction(this.dbValue);

  final String dbValue;

  /// Parses [raw] case-insensitively, throwing [FormatException] if unknown.
  static AuditAction fromDb(String raw) {
    final parsed = tryFromDb(raw);
    if (parsed == null) {
      throw FormatException('Unknown AuditAction value: "$raw"');
    }
    return parsed;
  }

  /// Parses [raw] or returns `null` when unrecognized.
  static AuditAction? tryFromDb(String raw) {
    final normalized = raw.trim().toLowerCase();
    for (final action in AuditAction.values) {
      if (action.dbValue == normalized || action.name.toLowerCase() == normalized) {
        return action;
      }
    }
    return null;
  }
}

/// Target domain table/collection referenced by an `activity_logs` entry.
enum AuditEntityType {
  employee('employee'),
  supplier('supplier'),
  customer('customer'),
  inventory('inventory'),
  order('order'),
  stockIn('stock_in'),
  stockOut('stock_out'),
  delivery('delivery'),
  payment('payment'),
  expense('expense'),
  auth('auth');

  const AuditEntityType(this.dbValue);

  final String dbValue;

  /// Parses [raw] case-insensitively, throwing [FormatException] if unknown.
  static AuditEntityType fromDb(String raw) {
    final parsed = tryFromDb(raw);
    if (parsed == null) {
      throw FormatException('Unknown AuditEntityType value: "$raw"');
    }
    return parsed;
  }

  /// Parses [raw] or returns `null` when unrecognized.
  static AuditEntityType? tryFromDb(String raw) {
    final normalized = raw.trim().toLowerCase();
    for (final entityType in AuditEntityType.values) {
      if (entityType.dbValue == normalized ||
          entityType.name.toLowerCase() == normalized) {
        return entityType;
      }
    }
    return null;
  }
}
