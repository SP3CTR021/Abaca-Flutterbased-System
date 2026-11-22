import 'package:abaca_system/core/config/backend_config.dart';
import 'package:abaca_system/core/data/fake/in_memory_database.dart';
import 'package:abaca_system/core/di/service_locator.dart';
import 'package:abaca_system/features/audit/domain/audit_domain.dart';
import 'package:abaca_system/features/auth/domain/auth_domain.dart';
import 'package:abaca_system/features/finance/domain/finance_domain.dart';
import 'package:abaca_system/features/inventory/domain/inventory_domain.dart';
import 'package:abaca_system/features/orders/domain/orders_domain.dart';
import 'package:abaca_system/features/partners/domain/partners_domain.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';

import 'contracts/audit_repository_contract.dart';
import 'contracts/auth_repository_contract.dart';
import 'contracts/customer_repository_contract.dart';
import 'contracts/delivery_repository_contract.dart';
import 'contracts/employee_repository_contract.dart';
import 'contracts/expense_repository_contract.dart';
import 'contracts/inventory_repository_contract.dart';
import 'contracts/order_repository_contract.dart';
import 'contracts/payment_repository_contract.dart';
import 'contracts/repository_test_harness.dart';
import 'contracts/stock_in_repository_contract.dart';
import 'contracts/stock_out_repository_contract.dart';
import 'contracts/supplier_repository_contract.dart';

Future<RepositoryTestHarness> createInMemoryHarness() async {
  final locator = GetIt.asNewInstance();
  final db = InMemoryDatabase();
  await configureDependencies(
    backend: BackendType.inMemory,
    locator: locator,
    inMemoryDatabase: db,
  );

  return RepositoryTestHarness(
    auditRepository: locator<AuditRepository>(),
    authRepository: locator<AuthRepository>(),
    employeeRepository: locator<EmployeeRepository>(),
    supplierRepository: locator<SupplierRepository>(),
    customerRepository: locator<CustomerRepository>(),
    inventoryRepository: locator<InventoryRepository>(),
    stockInRepository: locator<StockInRepository>(),
    stockOutRepository: locator<StockOutRepository>(),
    orderRepository: locator<OrderRepository>(),
    deliveryRepository: locator<DeliveryRepository>(),
    paymentRepository: locator<PaymentRepository>(),
    expenseRepository: locator<ExpenseRepository>(),
    onDispose: () async {
      await locator.reset();
      await db.dispose();
    },
  );
}

void main() {
  runAuthRepositoryContractTests(createInMemoryHarness);
  runEmployeeRepositoryContractTests(createInMemoryHarness);
  runSupplierRepositoryContractTests(createInMemoryHarness);
  runCustomerRepositoryContractTests(createInMemoryHarness);
  runInventoryRepositoryContractTests(createInMemoryHarness);
  runStockInRepositoryContractTests(createInMemoryHarness);
  runStockOutRepositoryContractTests(createInMemoryHarness);
  runOrderRepositoryContractTests(createInMemoryHarness);
  runDeliveryRepositoryContractTests(createInMemoryHarness);
  runPaymentRepositoryContractTests(createInMemoryHarness);
  runExpenseRepositoryContractTests(createInMemoryHarness);
  runAuditRepositoryContractTests(createInMemoryHarness);

  test('DI single-switch end-to-end abaca operational lifecycle', () async {
    final harness = await createInMemoryHarness();
    addTearDown(harness.dispose);

    final manager = await harness.seedEmployee(
      email: 'ops.manager@abaca.test',
      role: EmployeeRole.manager,
    );
    final driver = await harness.seedEmployee(
      firstName: 'Carlo',
      lastName: 'Driver',
      email: 'carlo@abaca.test',
      role: EmployeeRole.deliveryDriver,
    );
    final supplier = await harness.seedSupplier();
    final customer = await harness.seedCustomer();
    final s2 = await harness.seedGrade(
      abacaType: 'S2',
      minStockThresholdKg: 30,
    );

    // 1. Inbound receipt: +100 kg @ 45/kg = 4500 purchase cost.
    (await harness.stockInRepository.createStockIn(
      supplierId: supplier.id,
      employeeId: manager.id,
      dateReceived: DateTime(2026, 5, 1),
      items: <NewStockInItemInput>[
        NewStockInItemInput(
          inventoryId: s2.id,
          quantityKg: 100,
          costPerKg: 45,
        ),
      ],
    ))
        .getOrThrow();

    // 2. Customer order: 75 kg @ 100/kg = 7500 total.
    final order = (await harness.orderRepository.createOrder(
      customerId: customer.id,
      employeeId: manager.id,
      inventoryId: s2.id,
      orderDate: DateTime(2026, 5, 2),
      quantityKg: 75,
      pricePerKg: 100,
    ))
        .getOrThrow();
    (await harness.orderRepository.markOrderStocked(
      orderId: order.id,
      actorEmployeeId: manager.id,
    ))
        .getOrThrow();

    // 3. Dispatch & complete delivery -> 25 kg remains (triggers low-stock alert <= 30 kg).
    final delivery = (await harness.deliveryRepository.scheduleDelivery(
      orderId: order.id,
      employeeId: driver.id,
      deliveryDate: DateTime(2026, 5, 3),
    ))
        .getOrThrow();
    (await harness.deliveryRepository.completeDelivery(
      deliveryId: delivery.id,
      actorEmployeeId: driver.id,
    ))
        .getOrThrow();

    final remainingGrade =
        (await harness.inventoryRepository.getInventoryById(s2.id)).getOrThrow();
    expect(remainingGrade.currentStockKg, 25.0);
    expect(remainingGrade.isLowStock, isTrue);

    // 4. Partial + final payment -> fully paid.
    (await harness.paymentRepository.recordPayment(
      orderId: order.id,
      employeeId: manager.id,
      amountPaid: 3000,
      paymentDate: DateTime(2026, 5, 3),
      paymentMethod: 'Cash',
    ))
        .getOrThrow();
    (await harness.paymentRepository.recordPayment(
      orderId: order.id,
      employeeId: manager.id,
      amountPaid: 4500,
      paymentDate: DateTime(2026, 5, 4),
      paymentMethod: 'Bank Transfer',
    ))
        .getOrThrow();

    final details =
        (await harness.orderRepository.getOrderWithDetails(order.id))
            .getOrThrow();
    expect(details.order.status, OrderStatus.delivered);
    expect(details.paymentStatus, OrderPaymentStatus.paid);
    expect(details.remainingBalance, 0.0);

    // 5. Log operational expense & verify financial summary + audit log trail.
    (await harness.expenseRepository.createExpense(
      employeeId: manager.id,
      expenseType: 'Logistics',
      amount: 500,
      date: DateTime(2026, 5, 4),
    ))
        .getOrThrow();

    final summary =
        (await harness.expenseRepository.getFinancialSummary()).getOrThrow();
    expect(summary.totalOrderValue, 7500.0);
    expect(summary.totalPaymentsCollected, 7500.0);
    expect(summary.totalReceivables, 0.0);
    expect(summary.totalStockInPurchaseCost, 4500.0);
    expect(summary.totalOperationalExpenses, 500.0);
    expect(summary.netCashFlow, 2500.0);

    final auditLogs =
        (await harness.auditRepository.getActivityLogs()).getOrThrow();
    expect(
      auditLogs.map((l) => l.action),
      containsAll(<AuditAction>[
        AuditAction.created,
        AuditAction.statusChanged,
        AuditAction.deliveryCompleted,
        AuditAction.paymentRecorded,
      ]),
    );
  });
}
