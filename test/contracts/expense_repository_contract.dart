import 'package:abaca_system/core/types/query_filters.dart';
import 'package:abaca_system/features/inventory/domain/inventory_domain.dart';
import 'package:flutter_test/flutter_test.dart';

import 'repository_test_harness.dart';

void runExpenseRepositoryContractTests(HarnessFactory createHarness) {
  group('ExpenseRepository contract', () {
    late RepositoryTestHarness harness;

    setUp(() async {
      harness = await createHarness();
    });

    tearDown(() async {
      await harness.dispose();
    });

    test('CRUD and getFinancialSummary exclude cancelled orders and aggregate accurately',
        () async {
      final emp = await harness.seedEmployee();
      final supplier = await harness.seedSupplier();
      final customer = await harness.seedCustomer();
      final grade = await harness.seedGrade(abacaType: 'S2');

      // Purchase 50 kg @ 40/kg = 2000 purchase cost.
      (await harness.stockInRepository.createStockIn(
        supplierId: supplier.id,
        employeeId: emp.id,
        dateReceived: DateTime(2026, 5, 1),
        items: <NewStockInItemInput>[
          NewStockInItemInput(
            inventoryId: grade.id,
            quantityKg: 50,
            costPerKg: 40,
          ),
        ],
      ))
          .getOrThrow();

      // Active order: 30 kg @ 100/kg = 3000 order value.
      final activeOrder = (await harness.orderRepository.createOrder(
        customerId: customer.id,
        employeeId: emp.id,
        inventoryId: grade.id,
        orderDate: DateTime(2026, 5, 2),
        quantityKg: 30,
        pricePerKg: 100,
      ))
          .getOrThrow();
      (await harness.orderRepository.markOrderStocked(
        orderId: activeOrder.id,
        actorEmployeeId: emp.id,
      ))
          .getOrThrow();
      (await harness.paymentRepository.recordPayment(
        orderId: activeOrder.id,
        employeeId: emp.id,
        amountPaid: 1800,
        paymentDate: DateTime(2026, 5, 3),
        paymentMethod: 'Cash',
      ))
          .getOrThrow();

      // Cancelled order should be excluded from totalOrderValue & receivables.
      final cancelledOrder = (await harness.orderRepository.createOrder(
        customerId: customer.id,
        employeeId: emp.id,
        inventoryId: grade.id,
        orderDate: DateTime(2026, 5, 3),
        quantityKg: 10,
        pricePerKg: 100,
      ))
          .getOrThrow();
      (await harness.orderRepository.cancelOrder(
        orderId: cancelledOrder.id,
        actorEmployeeId: emp.id,
      ))
          .getOrThrow();

      // Operational expense: 350 -> update to 300.
      final exp = (await harness.expenseRepository.createExpense(
        employeeId: emp.id,
        expenseType: 'Truck Fuel',
        amount: 350,
        date: DateTime(2026, 5, 4),
      ))
          .getOrThrow();
      (await harness.expenseRepository.updateExpense(
        exp.copyWith(amount: 300),
        actorEmployeeId: emp.id,
      ))
          .getOrThrow();

      final summary = (await harness.expenseRepository.getFinancialSummary(
        dateRange: DateRangeFilter(
          startDate: DateTime(2026, 5, 1),
          endDate: DateTime(2026, 5, 31),
        ),
      ))
          .getOrThrow();

      expect(summary.totalOrderValue, 3000.0);
      expect(summary.totalPaymentsCollected, 1800.0);
      expect(summary.totalReceivables, 1200.0);
      expect(summary.totalStockInPurchaseCost, 2000.0);
      expect(summary.totalOperationalExpenses, 300.0);
      expect(summary.netCashFlow, -500.0); // 1800 - (2000 + 300)
    });
  });
}
