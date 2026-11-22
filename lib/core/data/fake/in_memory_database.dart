import 'dart:async';

import 'package:uuid/uuid.dart';

import '../../../features/audit/domain/entities/activity_log.dart';
import '../../../features/audit/domain/entities/audit_enums.dart';
import '../../../features/auth/domain/entities/employee.dart';
import '../../../features/finance/domain/entities/expense.dart';
import '../../../features/finance/domain/entities/payment.dart';
import '../../../features/inventory/domain/entities/inventory.dart';
import '../../../features/inventory/domain/entities/stock_in.dart';
import '../../../features/inventory/domain/entities/stock_in_item.dart';
import '../../../features/inventory/domain/entities/stock_out.dart';
import '../../../features/orders/domain/entities/delivery.dart';
import '../../../features/orders/domain/entities/order.dart';
import '../../../features/partners/domain/entities/customer.dart';
import '../../../features/partners/domain/entities/supplier.dart';

/// Reactive pure-Dart relational store backing all 12 in-memory fake repositories.
///
/// Mirrors every PostgreSQL / Firestore constraint (`UNIQUE` indexes,
/// `ON DELETE RESTRICT`, `ON DELETE CASCADE`, `ON DELETE SET NULL`,
/// `ON UPDATE CASCADE`, and atomic stock/payment/audit transactions) so
/// contract tests and offline workflows exercise identical semantics.
final class InMemoryDatabase {
  InMemoryDatabase({Uuid? uuid}) : _uuid = uuid ?? const Uuid();

  final Uuid _uuid;
  final StreamController<void> _changes = StreamController<void>.broadcast();
  int _lastTimestampMicros = 0;

  // Simulated Auth state & password hashes/values.
  final Map<String, String> passwordsByEmployeeId = <String, String>{};
  String? currentEmployeeId;

  // 12 domain tables keyed by String UUIDs.
  final Map<String, Employee> employees = <String, Employee>{};
  final Map<String, Supplier> suppliers = <String, Supplier>{};
  final Map<String, Customer> customers = <String, Customer>{};
  final Map<String, Inventory> inventory = <String, Inventory>{};
  final Map<String, Order> orders = <String, Order>{};
  final Map<String, Delivery> deliveries = <String, Delivery>{};
  final Map<String, StockIn> stockIns = <String, StockIn>{};
  final Map<String, List<StockInItem>> stockInItemsByStockInId =
      <String, List<StockInItem>>{};
  final Map<String, StockOut> stockOuts = <String, StockOut>{};
  final Map<String, Payment> payments = <String, Payment>{};
  final Map<String, Expense> expenses = <String, Expense>{};
  final List<ActivityLog> activityLogs = <ActivityLog>[];

  String nextId() => _uuid.v4();

  /// Generates a strictly monotonic UTC timestamp so rapid sequential test
  /// writes never collide on timestamp ordering.
  DateTime nextTimestamp() {
    var micros = DateTime.now().toUtc().microsecondsSinceEpoch;
    if (micros <= _lastTimestampMicros) {
      micros = _lastTimestampMicros + 1;
    }
    _lastTimestampMicros = micros;
    return DateTime.fromMicrosecondsSinceEpoch(micros, isUtc: true);
  }

  /// Appends an immutable [ActivityLog] entry. Callers invoke [notify] once
  /// after completing all writes in an atomic operation.
  ActivityLog recordAudit({
    String? actorEmployeeId,
    required AuditAction action,
    required AuditEntityType entityType,
    required String entityId,
    required String description,
    Map<String, Object?>? oldValues,
    Map<String, Object?>? newValues,
    DateTime? createdAt,
  }) {
    final entry = ActivityLog(
      id: nextId(),
      actorEmployeeId: actorEmployeeId,
      action: action,
      entityType: entityType,
      entityId: entityId,
      description: description,
      oldValues: oldValues,
      newValues: newValues,
      createdAt: createdAt ?? nextTimestamp(),
    );
    activityLogs.add(entry);
    return entry;
  }

  /// Broadcasts a table-state mutation to all active reactive watchers.
  void notify() {
    if (!_changes.isClosed) {
      _changes.add(null);
    }
  }

  /// Emits an initial snapshot immediately on subscription, followed by a fresh
  /// snapshot after each [notify] call.
  Stream<T> watch<T>(T Function() compute) async* {
    yield compute();
    await for (final _ in _changes.stream) {
      yield compute();
    }
  }

  Future<void> dispose() => _changes.close();
}
