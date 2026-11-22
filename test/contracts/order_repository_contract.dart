import 'package:abaca_system/core/errors/app_failure.dart';
import 'package:abaca_system/features/inventory/domain/inventory_domain.dart';
import 'package:abaca_system/features/orders/domain/orders_domain.dart';
import 'package:flutter_test/flutter_test.dart';

import 'repository_test_harness.dart';

void runOrderRepositoryContractTests(HarnessFactory createHarness) {
  group('OrderRepository contract', () {
    late RepositoryTestHarness harness;

    setUp(() async {
      harness = await createHarness();
    });

    tearDown(() async {
      await harness.dispose();
    });

    test('createOrder, updatePendingOrder, markStocked (no deduction yet), and cancel',
        () async {
      final emp = await harness.seedEmployee();
      final cust = await harness.seedCustomer();
      final grade = await harness.seedGrade(abacaType: 'S2', initialStockKg: 20);

      final order = (await harness.orderRepository.createOrder(
        customerId: cust.id,
        employeeId: emp.id,
        inventoryId: grade.id,
        orderDate: DateTime(2026, 5, 1),
        quantityKg: 10,
        pricePerKg: 90,
      ))
          .getOrThrow();
      expect(order.totalAmount, 900.0);
      expect(order.status, OrderStatus.pending);

      final edited = (await harness.orderRepository.updatePendingOrder(
        orderId: order.id,
        quantityKg: 25,
        actorEmployeeId: emp.id,
      ))
          .getOrThrow();
      expect(edited.totalAmount, 2250.0);

      // Marking stocked fails while stock (20) < requested (25).
      final insufficient = await harness.orderRepository.markOrderStocked(
        orderId: order.id,
        actorEmployeeId: emp.id,
      );
      expect(insufficient.failureOrNull, isA<InsufficientStockFailure>());

      // Adjust back down to 15 kg and mark stocked without deducting stock yet.
      (await harness.orderRepository.updatePendingOrder(
        orderId: order.id,
        quantityKg: 15,
        actorEmployeeId: emp.id,
      ))
          .getOrThrow();

      final stocked = (await harness.orderRepository.markOrderStocked(
        orderId: order.id,
        actorEmployeeId: emp.id,
      ))
          .getOrThrow();
      expect(stocked.status, OrderStatus.stocked);
      expect(
        (await harness.inventoryRepository.getInventoryById(grade.id))
            .getOrThrow()
            .currentStockKg,
        20.0,
      );

      // Editing after stocked is rejected.
      final editAfterStocked = await harness.orderRepository.updatePendingOrder(
        orderId: order.id,
        quantityKg: 12,
        actorEmployeeId: emp.id,
      );
      expect(
        editAfterStocked.failureOrNull,
        isA<InvalidStateTransitionFailure>(),
      );

      // Scheduling a pending delivery then cancelling order removes pending delivery.
      (await harness.deliveryRepository.scheduleDelivery(
        orderId: order.id,
        employeeId: emp.id,
        deliveryDate: DateTime(2026, 5, 3),
      ))
          .getOrThrow();

      final cancelled = (await harness.orderRepository.cancelOrder(
        orderId: order.id,
        actorEmployeeId: emp.id,
        reason: 'Customer postponed',
      ))
          .getOrThrow();
      expect(cancelled.status, OrderStatus.cancelled);
      expect(
        (await harness.deliveryRepository.getDeliveryByOrderId(order.id))
            .getOrThrow(),
        isNull,
      );
    });

    test('deleteOrder nullifies stock_ins.order_id (SET NULL) and restricts when paid',
        () async {
      final emp = await harness.seedEmployee();
      final cust = await harness.seedCustomer();
      final sup = await harness.seedSupplier();
      final grade = await harness.seedGrade(abacaType: 'S3', initialStockKg: 50);

      final order = (await harness.orderRepository.createOrder(
        customerId: cust.id,
        employeeId: emp.id,
        inventoryId: grade.id,
        orderDate: DateTime(2026, 5, 1),
        quantityKg: 10,
        pricePerKg: 50,
      ))
          .getOrThrow();

      final receipt = (await harness.stockInRepository.createStockIn(
        orderId: order.id,
        supplierId: sup.id,
        employeeId: emp.id,
        dateReceived: DateTime(2026, 5, 2),
        items: <NewStockInItemInput>[
          NewStockInItemInput(
            inventoryId: grade.id,
            quantityKg: 10,
            costPerKg: 30,
          ),
        ],
      ))
          .getOrThrow();

      (await harness.orderRepository.deleteOrder(order.id)).getOrThrow();

      final refreshedReceipt = (await harness.stockInRepository
              .getStockInWithItems(receipt.stockIn.id))
          .getOrThrow();
      expect(refreshedReceipt.stockIn.orderId, isNull);

      // Order with payment cannot be deleted.
      final paidOrder = (await harness.orderRepository.createOrder(
        customerId: cust.id,
        employeeId: emp.id,
        inventoryId: grade.id,
        orderDate: DateTime(2026, 5, 3),
        quantityKg: 10,
        pricePerKg: 100,
      ))
          .getOrThrow();
      (await harness.orderRepository.markOrderStocked(
        orderId: paidOrder.id,
        actorEmployeeId: emp.id,
      ))
          .getOrThrow();
      (await harness.paymentRepository.recordPayment(
        orderId: paidOrder.id,
        employeeId: emp.id,
        amountPaid: 200,
        paymentDate: DateTime(2026, 5, 4),
        paymentMethod: 'Cash',
      ))
          .getOrThrow();

      final blockedDelete =
          await harness.orderRepository.deleteOrder(paidOrder.id);
      expect(blockedDelete.failureOrNull, isA<ConflictFailure>());
    });
  });
}
