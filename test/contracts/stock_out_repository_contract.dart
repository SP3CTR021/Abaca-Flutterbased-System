import 'package:abaca_system/core/errors/app_failure.dart';
import 'package:abaca_system/features/inventory/domain/inventory_domain.dart';
import 'package:flutter_test/flutter_test.dart';

import 'repository_test_harness.dart';

void runStockOutRepositoryContractTests(HarnessFactory createHarness) {
  group('StockOutRepository contract', () {
    late RepositoryTestHarness harness;

    setUp(() async {
      harness = await createHarness();
    });

    tearDown(() async {
      await harness.dispose();
    });

    test('blocks manual released stock-out and insufficient stock', () async {
      final emp = await harness.seedEmployee();
      final grade = await harness.seedGrade(abacaType: 'S2', initialStockKg: 25);

      final manualReleased = await harness.stockOutRepository.createStockOut(
        inventoryId: grade.id,
        employeeId: emp.id,
        quantityKg: 5,
        reason: StockOutReason.released,
        date: DateTime(2026, 5, 5),
      );
      expect(
        manualReleased.failureOrNull,
        isA<InvalidStateTransitionFailure>(),
      );

      final tooMuch = await harness.stockOutRepository.createStockOut(
        inventoryId: grade.id,
        employeeId: emp.id,
        quantityKg: 30,
        reason: StockOutReason.lost,
        date: DateTime(2026, 5, 5),
      );
      expect(tooMuch.failureOrNull, isA<InsufficientStockFailure>());
    });

    test('manual stock-out deducts and restores on delete; blocks delivery-linked delete',
        () async {
      final emp = await harness.seedEmployee();
      final cust = await harness.seedCustomer();
      final grade = await harness.seedGrade(abacaType: 'S2', initialStockKg: 50);

      final manual = (await harness.stockOutRepository.createStockOut(
        inventoryId: grade.id,
        employeeId: emp.id,
        quantityKg: 10,
        reason: StockOutReason.damaged,
        notes: 'Moisture damage',
        date: DateTime(2026, 5, 5),
      ))
          .getOrThrow();

      expect(
        (await harness.inventoryRepository.getInventoryById(grade.id))
            .getOrThrow()
            .currentStockKg,
        40.0,
      );

      (await harness.stockOutRepository.deleteStockOut(manual.id)).getOrThrow();
      expect(
        (await harness.inventoryRepository.getInventoryById(grade.id))
            .getOrThrow()
            .currentStockKg,
        50.0,
      );

      // Complete a delivery to generate a delivery-linked stock_out.
      final order = (await harness.orderRepository.createOrder(
        customerId: cust.id,
        employeeId: emp.id,
        inventoryId: grade.id,
        orderDate: DateTime(2026, 5, 6),
        quantityKg: 15,
        pricePerKg: 100,
      ))
          .getOrThrow();
      (await harness.orderRepository.markOrderStocked(
        orderId: order.id,
        actorEmployeeId: emp.id,
      ))
          .getOrThrow();
      final delivery = (await harness.deliveryRepository.scheduleDelivery(
        orderId: order.id,
        employeeId: emp.id,
        deliveryDate: DateTime(2026, 5, 7),
      ))
          .getOrThrow();
      (await harness.deliveryRepository.completeDelivery(
        deliveryId: delivery.id,
        actorEmployeeId: emp.id,
      ))
          .getOrThrow();

      final released = (await harness.stockOutRepository.getStockOuts(
        orderId: order.id,
        reason: StockOutReason.released,
      ))
          .getOrThrow();
      expect(released.length, 1);
      expect(released.first.deliveryId, delivery.id);

      final blockedDelete =
          await harness.stockOutRepository.deleteStockOut(released.first.id);
      expect(blockedDelete.failureOrNull, isA<InvalidStateTransitionFailure>());
    });
  });
}
