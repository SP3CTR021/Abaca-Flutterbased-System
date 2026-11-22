import 'package:abaca_system/core/errors/app_failure.dart';
import 'package:flutter_test/flutter_test.dart';

import 'repository_test_harness.dart';

void runInventoryRepositoryContractTests(HarnessFactory createHarness) {
  group('InventoryRepository contract', () {
    late RepositoryTestHarness harness;

    setUp(() async {
      harness = await createHarness();
    });

    tearDown(() async {
      await harness.dispose();
    });

    test('enforces unique abacaType, low-stock filtering, and rename cascade',
        () async {
      final s2 = await harness.seedGrade(
        abacaType: 'S2',
        initialStockKg: 10,
        minStockThresholdKg: 20,
      );
      await harness.seedGrade(
        abacaType: 'G',
        initialStockKg: 100,
        minStockThresholdKg: 25,
      );

      final dup = await harness.inventoryRepository.createGrade(abacaType: 's2');
      expect(dup.failureOrNull, isA<ConflictFailure>());

      final byType =
          (await harness.inventoryRepository.getInventoryByAbacaType('s2'))
              .getOrThrow();
      expect(byType.id, s2.id);

      final lowOnly = (await harness.inventoryRepository
              .getAllInventory(onlyLowStock: true))
          .getOrThrow();
      expect(lowOnly.map((i) => i.id), <String>[s2.id]);

      final emp = await harness.seedEmployee();
      final cust = await harness.seedCustomer();
      final order = (await harness.orderRepository.createOrder(
        customerId: cust.id,
        employeeId: emp.id,
        inventoryId: s2.id,
        orderDate: DateTime(2026, 5, 2),
        quantityKg: 5,
        pricePerKg: 80,
      ))
          .getOrThrow();

      final renamed = (await harness.inventoryRepository.updateGradeMetadata(
        id: s2.id,
        abacaType: 'S2-Premium',
        clearDescription: true,
        minStockThresholdKg: 5,
      ))
          .getOrThrow();
      expect(renamed.abacaType, 'S2-Premium');
      expect(renamed.description, isNull);
      expect(renamed.isLowStock, isFalse);

      // Verify ON UPDATE CASCADE propagated new abacaType onto existing orders.
      final updatedOrder =
          (await harness.orderRepository.getOrderById(order.id)).getOrThrow();
      expect(updatedOrder.abacaType, 'S2-Premium');

      // Verify ON DELETE RESTRICT blocks deleting grade referenced by an order.
      final blocked = await harness.inventoryRepository.deleteGrade(s2.id);
      expect(blocked.failureOrNull, isA<ConflictFailure>());
    });
  });
}
