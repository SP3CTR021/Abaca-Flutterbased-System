/// Staff roles governing access control (Supabase RLS & Firestore rules).
enum EmployeeRole {
  manager('manager', 'Manager'),
  warehouseStaff('warehouse_staff', 'Warehouse Staff'),
  deliveryDriver('delivery_driver', 'Delivery Driver'),
  accountant('accountant', 'Accountant');

  const EmployeeRole(this.dbValue, this.displayName);

  /// Canonical lowercase snake_case value persisted in Postgres/Firestore.
  final String dbValue;

  /// Human-readable role label (also matches legacy Laravel seed strings).
  final String displayName;

  /// Parses [raw] from canonical snake_case, display name, or mixed casing.
  ///
  /// Throws a [FormatException] when [raw] does not match a known role.
  static EmployeeRole fromDb(String raw) {
    final parsed = tryFromDb(raw);
    if (parsed == null) {
      throw FormatException('Unknown EmployeeRole value: "$raw"');
    }
    return parsed;
  }

  /// Parses [raw] or returns `null` when unrecognized.
  static EmployeeRole? tryFromDb(String raw) {
    final normalized = raw.trim().toLowerCase().replaceAll(RegExp(r'[\s-]+'), '_');
    for (final role in EmployeeRole.values) {
      if (role.dbValue == normalized ||
          role.name.toLowerCase() == normalized.replaceAll('_', '')) {
        return role;
      }
    }
    return null;
  }
}
