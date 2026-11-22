import 'package:abaca_system/core/errors/app_failure.dart';
import 'package:abaca_system/features/auth/domain/auth_domain.dart';
import 'package:abaca_system/features/inventory/domain/inventory_domain.dart';
import 'package:abaca_system/features/orders/domain/orders_domain.dart';
import 'package:flutter_test/flutter_test.dart';

import 'repository_test_harness.dart';

void runDeliveryRepositoryContractTests(HarnessFactory createHarness) {
  group('DeliveryRepository contract', () {
    late RepositoryTestHarness harness;

    setUp(() async {
      harness = await createHarness();
    });

    tearDown(() async {
      await harness.dispose();
    });

    test('enforces 1:1 schedule per stocked order and single-deduction completion',
        () async {
      final mgr = await harness.seedEmployee(email: 'mgr@abaca.test');
      final driver1 = await harness.seedEmployee(
        firstName: 'Driver',
        lastName: 'One',
        email: 'driver1@abaca.test',
        role: EmployeeRole.deliveryDriver,
      );
      final driver2 = await harness.seedEmployee(
        firstName: 'Driver',
        lastName: 'Two',
        email: 'driver2@abaca.test',
        role: EmployeeRole.deliveryDriver,
      );
      final cust = await harness.seedCustomer();
      final grade = await harness.seedGrade(abacaType: 'S2', initialStockKg: 50);

      final order = (await harness.orderRepository.createOrder(
        customerId: cust.id,
        employeeId: mgr.id,
        inventoryId: grade.id,
        orderDate: DateTime(2026, 5, 1),
        quantityKg: 18,
        pricePerKg: 100,
      ))
          .getOrThrow();

      // Cannot schedule delivery while order is still pending.
      final pendingSchedule = await harness.deliveryRepository.scheduleDelivery(
        orderId: order.id,
        employeeId: driver1.id,
        deliveryDate: DateTime(2026, 5, 2),
      );
      expect(
        pendingSchedule.failureOrNull,
        isA<InvalidStateTransitionFailure>(),
      );

      (await harness.orderRepository.markOrderStocked(
        orderId: order.id,
        actorEmployeeId: mgr.id,
      ))
          .getOrThrow();

      final scheduled = (await harness.deliveryRepository.scheduleDelivery(
        orderId: order.id,
        employeeId: driver1.id,
        deliveryDate: DateTime(2026, 5, 2),
      ))
          .getOrThrow();

      // Strict 1:1 per order rejects a second delivery.
      final duplicateSchedule =
          await harness.deliveryRepository.scheduleDelivery(
        orderId: order.id,
        employeeId: driver2.id,
        deliveryDate: DateTime(2026, 5, 2),
      );
      expect(duplicateSchedule.failureOrNull, isA<ConflictFailure>());

      final reassigned = (await harness.deliveryRepository.reassignDelivery(
        deliveryId: scheduled.id,
        newEmployeeId: driver2.id,
        actorEmployeeId: mgr.id,
      ))
          .getOrThrow();
      expect(reassigned.employeeId, driver2.id);

      final completed = (await harness.deliveryRepository.completeDelivery(
        deliveryId: scheduled.id,
        actorEmployeeId: driver2.id,
        notes: 'Signed by buyer',
      ))
          .getOrThrow();
      expect(completed.status, DeliveryStatus.delivered);
      expect(completed.deliveredAt, isNotNull);

      // Single deduction: 50 - 18 = 32 kg (NEVER double-deducted to 14!).
      expect(
        (await harness.inventoryRepository.getInventoryById(grade.id))
            .getOrThrow()
            .currentStockKg,
        32.0,
      );

      // Order transitioned atomically to delivered.
      expect(
        (await harness.orderRepository.getOrderById(order.id))
            .getOrThrow()
            .status,
        OrderStatus.delivered,
      );

      // Exactly 1 linked StockOut(reason: released, deliveryId: scheduled.id).
      final stockOuts = (await harness.stockOutRepository.getStockOuts(
        orderId: order.id,
      ))
          .getOrThrow();
      expect(stockOuts.length, 1);
      expect(stockOuts.first.reason, StockOutReason.released);
      expect(stockOuts.first.deliveryId, scheduled.id);
      expect(stockOuts.first.quantityKg, 18.0);

      // Cannot complete twice or reassign once delivered.
      final completeAgain = await harness.deliveryRepository.completeDelivery(
        deliveryId: scheduled.id,
        actorEmployeeId: driver2.id,
      );
      expect(
        completeAgain.failureOrNull,
        isA<InvalidStateTransitionFailure>(),
      );

      final reassignAfterDone =
          await harness.deliveryRepository.reassignDelivery(
        deliveryId: scheduled.id,
        newEmployeeId: driver1.id,
        actorEmployeeId: mgr.id,
      );
      expect(
        reassignAfterDone.failureOrNull,
        isA<InvalidStateTransitionFailure>(),
      );
    });
  });
}
