import 'package:abaca_system/core/errors/app_failure.dart';
import 'package:abaca_system/features/inventory/domain/inventory_domain.dart';
import 'package:flutter_test/flutter_test.dart';

import 'repository_test_harness.dart';

void runStockInRepositoryContractTests(HarnessFactory createHarness) {
  group('StockInRepository contract', () {
    late RepositoryTestHarness harness;

    setUp(() async {
      harness = await createHarness();
    });

    tearDown(() async {
      await harness.dispose();
    });

    test('multi-item stock-in updates balances and reverses safely on delete',
        () async {
      final emp = await harness.seedEmployee();
      final supplier = await harness.seedSupplier();
      final s2 = await harness.seedGrade(abacaType: 'S2');
      final jk = await harness.seedGrade(abacaType: 'JK');

      final receipt = (await harness.stockInRepository.createStockIn(
        supplierId: supplier.id,
        employeeId: emp.id,
        dateReceived: DateTime(2026, 5, 3),
        items: <NewStockInItemInput>[
          NewStockInItemInput(
            inventoryId: s2.id,
            quantityKg: 40,
            costPerKg: 55,
          ),
          NewStockInItemInput(
            inventoryId: jk.id,
            quantityKg: 15,
            costPerKg: 35,
          ),
        ],
      ))
          .getOrThrow();

      expect(receipt.items.length, 2);
      expect(receipt.totalQuantityKg, 55.0);
      expect(receipt.totalCost, 2725.0);

      expect(
        (await harness.inventoryRepository.getInventoryById(s2.id))
            .getOrThrow()
            .currentStockKg,
        40.0,
      );

      // Deduct 30 kg of S2 so deleting the 40 kg stock-in would go negative.
      (await harness.stockOutRepository.createStockOut(
        inventoryId: s2.id,
        employeeId: emp.id,
        quantityKg: 30,
        reason: StockOutReason.damaged,
        date: DateTime(2026, 5, 4),
      ))
          .getOrThrow();

      final blockedDelete = await harness.stockInRepository.deleteStockIn(
        receipt.stockIn.id,
        actorEmployeeId: emp.id,
      );
      expect(blockedDelete.failureOrNull, isA<InsufficientStockFailure>());

      // Delete the unused receipt cleanly after a clean receipt test.
      final secondReceipt = (await harness.stockInRepository.createStockIn(
        supplierId: supplier.id,
        employeeId: emp.id,
        dateReceived: DateTime(2026, 5, 5),
        items: <NewStockInItemInput>[
          NewStockInItemInput(
            inventoryId: jk.id,
            quantityKg: 10,
            costPerKg: 40,
          ),
        ],
      ))
          .getOrThrow();

      (await harness.stockInRepository.deleteStockIn(secondReceipt.stockIn.id))
          .getOrThrow();
      expect(
        (await harness.inventoryRepository.getInventoryById(jk.id))
            .getOrThrow()
            .currentStockKg,
        15.0,
      );
    });
  });
}
