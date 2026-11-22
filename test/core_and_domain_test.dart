import 'package:abaca_system/core/errors/app_failure.dart';
import 'package:abaca_system/core/result/result.dart';
import 'package:abaca_system/core/types/query_filters.dart';
import 'package:abaca_system/core/utils/decimal_precision.dart';
import 'package:abaca_system/features/audit/domain/audit_domain.dart';
import 'package:abaca_system/features/auth/domain/auth_domain.dart';
import 'package:abaca_system/features/finance/domain/finance_domain.dart';
import 'package:abaca_system/features/inventory/domain/inventory_domain.dart';
import 'package:abaca_system/features/orders/domain/orders_domain.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DecimalPrecision', () {
    test('avoids IEEE-754 floating-point drift on 2-decimal math', () {
      expect(DecimalPrecision.add2(0.1, 0.2), 0.3);
      expect(DecimalPrecision.subtract2(10.3, 0.1), 10.2);
      expect(DecimalPrecision.multiply2(12.34, 5.67), 69.97);
      expect(
        DecimalPrecision.sum2(const <double>[0.1, 0.2, 0.3, 19.4]),
        20.0,
      );
      expect(DecimalPrecision.equals2(10.004, 10.001), isTrue);
      expect(DecimalPrecision.compare2(10.50, 10.49), 1);
    });
  });

  group('Result & AppFailure', () {
    test('Result fold, map, flatMap, getOrThrow, and value equality', () {
      const ok = Result<int>.ok(42);
      expect(ok.isOk, isTrue);
      expect(ok.valueOrNull, 42);
      expect(ok.map((v) => v * 2).getOrThrow(), 84);
      expect(
        ok.flatMap((v) => Result<String>.ok('n=$v')).fold(
              (_) => 'err',
              (value) => value,
            ),
        'n=42',
      );

      final validationA = ValidationFailure(
        message: 'Invalid',
        fieldErrors: const <String, String>{'qty': 'Must be > 0'},
      );
      final validationB = ValidationFailure(
        message: 'Invalid',
        fieldErrors: const <String, String>{'qty': 'Must be > 0'},
      );
      expect(validationA, equals(validationB));
      expect(validationA.hashCode, equals(validationB.hashCode));
      expect(() => validationA.fieldErrors['extra'] = 'x', throwsUnsupportedError);

      final err = Result<int>.err(validationA);
      expect(err.isErr, isTrue);
      expect(err.failureOrNull, validationA);
      expect(err.getOrThrow, throwsA(isA<ValidationFailure>()));
    });
  });

  group('DateRangeFilter', () {
    test('treats midnight endDate inclusively across the full calendar day', () {
      final filter = DateRangeFilter(
        startDate: DateTime(2026, 5, 1),
        endDate: DateTime(2026, 5, 31),
      );
      expect(filter.isValid, isTrue);
      expect(filter.contains(DateTime(2026, 5, 1, 0, 0)), isTrue);
      expect(filter.contains(DateTime(2026, 5, 31, 23, 59, 59)), isTrue);
      expect(filter.contains(DateTime(2026, 4, 30, 23, 59)), isFalse);
      expect(filter.contains(DateTime(2026, 6, 1, 0, 0)), isFalse);

      final invalid = DateRangeFilter(
        startDate: DateTime(2026, 6, 1),
        endDate: DateTime(2026, 5, 1),
      );
      expect(invalid.isValid, isFalse);
    });
  });

  group('Domain enums and entity behaviors', () {
    test('parses all domain enums from DB values and display strings', () {
      expect(EmployeeRole.fromDb('Warehouse Staff'), EmployeeRole.warehouseStaff);
      expect(EmployeeRole.fromDb('delivery_driver'), EmployeeRole.deliveryDriver);
      expect(EmployeeRole.tryFromDb('unknown'), isNull);

      expect(OrderStatus.fromDb('STOCKED'), OrderStatus.stocked);
      expect(DeliveryStatus.fromDb('delivered'), DeliveryStatus.delivered);
      expect(StockOutReason.fromDb('damaged'), StockOutReason.damaged);
      expect(
        AuditAction.fromDb('delivery_completed'),
        AuditAction.deliveryCompleted,
      );
      expect(AuditEntityType.fromDb('stock_in'), AuditEntityType.stockIn);
    });

    test('Inventory low-stock alerts, copyWith clear flags, and composite read models',
        () {
      final now = DateTime.utc(2026, 5, 1, 12);
      final inv = Inventory(
        id: 'inv-1',
        abacaType: 'S2',
        description: 'Top grade',
        currentStockKg: 20.0,
        minStockThresholdKg: 25.0,
        createdAt: now,
        lastUpdated: now,
      );
      expect(inv.isLowStock, isTrue);
      expect(inv.isOutOfStock, isFalse);

      final cleared = inv.copyWith(clearDescription: true, currentStockKg: 0.0);
      expect(cleared.description, isNull);
      expect(cleared.isOutOfStock, isTrue);

      final emp = Employee(
        id: 'emp-1',
        firstName: 'Ana',
        middleName: 'B',
        lastName: 'Belena',
        email: 'ana@abaca.test',
        role: EmployeeRole.manager,
        createdAt: now,
        updatedAt: now,
      );
      expect(emp.fullName, 'Ana B Belena');
      expect(emp.copyWith(clearMiddleName: true).fullName, 'Ana Belena');

      final order = Order(
        id: 'ord-1',
        customerId: 'cust-1',
        employeeId: emp.id,
        inventoryId: inv.id,
        abacaType: 'S2',
        orderDate: DateTime(2026, 5, 1),
        quantityKg: 10,
        pricePerKg: 100,
        totalAmount: 1000,
        status: OrderStatus.stocked,
        createdAt: now,
        updatedAt: now,
      );
      final payment = Payment(
        id: 'pay-1',
        orderId: order.id,
        employeeId: emp.id,
        amountPaid: 400,
        paymentDate: DateTime(2026, 5, 2),
        paymentMethod: 'Cash',
        createdAt: now,
        updatedAt: now,
      );
      final details = OrderWithDetails(
        order: order,
        payments: <Payment>[payment],
      );
      expect(details.totalPaid, 400.0);
      expect(details.remainingBalance, 600.0);
      expect(details.paymentStatus, OrderPaymentStatus.partiallyPaid);
      expect(() => details.payments.add(payment), throwsUnsupportedError);

      final stockIn = StockInWithDetails(
        stockIn: StockIn(
          id: 'si-1',
          supplierId: 'sup-1',
          employeeId: emp.id,
          dateReceived: DateTime(2026, 5, 1),
          createdAt: now,
          updatedAt: now,
        ),
        items: <StockInItem>[
          StockInItem(
            id: 'item-1',
            stockInId: 'si-1',
            inventoryId: inv.id,
            quantityKg: 12.5,
            costPerKg: 40.0,
            createdAt: now,
            updatedAt: now,
          ),
        ],
      );
      expect(stockIn.totalQuantityKg, 12.5);
      expect(stockIn.totalCost, 500.0);

      const summary = FinancialSummary(
        totalOrderValue: 1000,
        totalPaymentsCollected: 900,
        totalReceivables: 100,
        totalStockInPurchaseCost: 500,
        totalOperationalExpenses: 150,
      );
      expect(summary.netCashFlow, 250.0);

      final log = ActivityLog(
        id: 'log-1',
        actorEmployeeId: emp.id,
        action: AuditAction.created,
        entityType: AuditEntityType.order,
        entityId: order.id,
        description: 'Created',
        newValues: const <String, Object?>{'total': 1000},
        createdAt: now,
      );
      expect(() => log.newValues!['total'] = 0, throwsUnsupportedError);
    });
  });
}
