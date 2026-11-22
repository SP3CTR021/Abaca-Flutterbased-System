import 'package:abaca_system/core/errors/app_failure.dart';
import 'package:abaca_system/features/inventory/domain/inventory_domain.dart';
import 'package:flutter_test/flutter_test.dart';

import 'repository_test_harness.dart';

void runSupplierRepositoryContractTests(HarnessFactory createHarness) {
  group('SupplierRepository contract', () {
    late RepositoryTestHarness harness;

    setUp(() async {
      harness = await createHarness();
    });

    tearDown(() async {
      await harness.dispose();
    });

    test('CRUD, searchQuery, archival, and watchSuppliers', () async {
      final mario = await harness.seedSupplier(
        firstName: 'Mario',
        lastName: 'Reyes',
        address: 'Daraga, Albay (500-char test)',
      );
      await harness.seedSupplier(
        firstName: 'Elena',
        lastName: 'Santos',
        contactNumber: '09998887777',
      );

      final searchRes = (await harness.supplierRepository
              .getSuppliers(searchQuery: 'mario reyes'))
          .getOrThrow();
      expect(searchRes.map((s) => s.id), <String>[mario.id]);

      final updated = (await harness.supplierRepository.updateSupplier(
        mario.copyWith(address: 'Legazpi City'),
      ))
          .getOrThrow();
      expect(updated.address, 'Legazpi City');

      await harness.supplierRepository
          .setSupplierActive(id: mario.id, isActive: false);
      final archivedWatch =
          await harness.supplierRepository.watchSuppliers(isActive: false).first;
      expect(archivedWatch.map((s) => s.id), <String>[mario.id]);
    });

    test('ON DELETE RESTRICT blocks deleting supplier referenced by stock_in',
        () async {
      final emp = await harness.seedEmployee();
      final supplier = await harness.seedSupplier();
      final grade = await harness.seedGrade(abacaType: 'S2');

      (await harness.stockInRepository.createStockIn(
        supplierId: supplier.id,
        employeeId: emp.id,
        dateReceived: DateTime(2026, 5, 1),
        items: <NewStockInItemInput>[
          NewStockInItemInput(
            inventoryId: grade.id,
            quantityKg: 20,
            costPerKg: 50,
          ),
        ],
      ))
          .getOrThrow();

      final blocked =
          await harness.supplierRepository.deleteSupplier(supplier.id);
      expect(blocked.failureOrNull, isA<ConflictFailure>());
    });
  });
}
