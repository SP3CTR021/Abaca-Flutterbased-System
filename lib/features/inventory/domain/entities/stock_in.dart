import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import '../../../../core/utils/decimal_precision.dart';
import 'stock_in_item.dart';

/// Inbound stock receipt header (`stock_ins` table / root collection).
///
/// Relationships:
/// - `N:1` optional child of `orders` (`stock_ins.order_id`, `ON DELETE SET NULL`).
/// - `N:1` child of `suppliers` (`stock_ins.supplier_id`, `ON DELETE RESTRICT`).
/// - `N:1` child of `employees` (`stock_ins.employee_id`, `ON DELETE RESTRICT`).
/// - `1:N` parent of `stock_in_items` (`stock_in_items.stockin_id`, `ON DELETE CASCADE`).
@immutable
final class StockIn {
  const StockIn({
    required this.id,
    this.orderId,
    required this.supplierId,
    required this.employeeId,
    required this.dateReceived,
    this.notes,
    required this.createdAt,
    required this.updatedAt,
  });

  /// Primary key (`stockin_id`).
  final String id;

  /// Optional linked customer order (`stock_ins.order_id`, `ON DELETE SET NULL`).
  final String? orderId;
  final String supplierId;
  final String employeeId;
  final DateTime dateReceived;
  final String? notes;
  final DateTime createdAt;
  final DateTime updatedAt;

  StockIn copyWith({
    String? id,
    String? orderId,
    bool clearOrderId = false,
    String? supplierId,
    String? employeeId,
    DateTime? dateReceived,
    String? notes,
    bool clearNotes = false,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) =>
      StockIn(
        id: id ?? this.id,
        orderId: clearOrderId ? null : (orderId ?? this.orderId),
        supplierId: supplierId ?? this.supplierId,
        employeeId: employeeId ?? this.employeeId,
        dateReceived: dateReceived ?? this.dateReceived,
        notes: clearNotes ? null : (notes ?? this.notes),
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StockIn &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          orderId == other.orderId &&
          supplierId == other.supplierId &&
          employeeId == other.employeeId &&
          dateReceived == other.dateReceived &&
          notes == other.notes &&
          createdAt == other.createdAt &&
          updatedAt == other.updatedAt;

  @override
  int get hashCode => Object.hash(
        runtimeType,
        id,
        orderId,
        supplierId,
        employeeId,
        dateReceived,
        notes,
        createdAt,
        updatedAt,
      );

  @override
  String toString() =>
      'StockIn(id: $id, supplierId: $supplierId, orderId: $orderId, dateReceived: $dateReceived)';
}

/// Composite read model bundling a [StockIn] header with its line [items] and
/// display labels resolved via SQL join (Supabase) or DTO denormalization (Firestore).
@immutable
final class StockInWithDetails {
  StockInWithDetails({
    required this.stockIn,
    List<StockInItem> items = const <StockInItem>[],
    this.supplierName,
    this.employeeName,
    Map<String, String> abacaTypeByInventoryId = const <String, String>{},
  })  : items = List<StockInItem>.unmodifiable(items),
        abacaTypeByInventoryId =
            Map<String, String>.unmodifiable(abacaTypeByInventoryId);

  final StockIn stockIn;
  final List<StockInItem> items;
  final String? supplierName;
  final String? employeeName;
  final Map<String, String> abacaTypeByInventoryId;

  /// Total inbound fiber weight across all line items (`kg`).
  double get totalQuantityKg =>
      DecimalPrecision.sum2(items.map((item) => item.quantityKg));

  /// Total supplier purchase cost across all line items.
  double get totalCost =>
      DecimalPrecision.sum2(items.map((item) => item.totalCost));

  static const ListEquality<StockInItem> _listEquality =
      ListEquality<StockInItem>();
  static const MapEquality<String, String> _mapEquality =
      MapEquality<String, String>();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StockInWithDetails &&
          runtimeType == other.runtimeType &&
          stockIn == other.stockIn &&
          _listEquality.equals(items, other.items) &&
          supplierName == other.supplierName &&
          employeeName == other.employeeName &&
          _mapEquality.equals(
            abacaTypeByInventoryId,
            other.abacaTypeByInventoryId,
          );

  @override
  int get hashCode => Object.hash(
        runtimeType,
        stockIn,
        _listEquality.hash(items),
        supplierName,
        employeeName,
        _mapEquality.hash(abacaTypeByInventoryId),
      );
}
