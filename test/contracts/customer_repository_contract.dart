import 'package:abaca_system/core/errors/app_failure.dart';
import 'package:flutter_test/flutter_test.dart';

import 'repository_test_harness.dart';

void runCustomerRepositoryContractTests(HarnessFactory createHarness) {
  group('CustomerRepository contract', () {
    late RepositoryTestHarness harness;

    setUp(() async {
      harness = await createHarness();
    });

    tearDown(() async {
      await harness.dispose();
    });

    test('CRUD, full-name searchQuery, archival, and watchCustomers', () async {
      final juan = await harness.seedCustomer(
        firstName: 'Juan',
        lastName: 'Cruz',
      );
      await harness.seedCustomer(
        firstName: 'Maria',
        lastName: 'Clara',
      );

      final found = (await harness.customerRepository
              .getCustomers(searchQuery: 'juan cruz'))
          .getOrThrow();
      expect(found.map((c) => c.id), <String>[juan.id]);

      await harness.customerRepository
          .setCustomerActive(id: juan.id, isActive: false);
      final activeWatch =
          await harness.customerRepository.watchCustomers(isActive: true).first;
      expect(activeWatch.length, 1);
      expect(activeWatch.first.firstName, 'Maria');
    });

    test('ON DELETE RESTRICT blocks deleting customer with existing orders',
        () async {
      final emp = await harness.seedEmployee();
      final cust = await harness.seedCustomer();
      final grade = await harness.seedGrade(abacaType: 'S2');

      (await harness.orderRepository.createOrder(
        customerId: cust.id,
        employeeId: emp.id,
        inventoryId: grade.id,
        orderDate: DateTime(2026, 5, 1),
        quantityKg: 10,
        pricePerKg: 100,
      ))
          .getOrThrow();

      final blocked =
          await harness.customerRepository.deleteCustomer(cust.id);
      expect(blocked.failureOrNull, isA<ConflictFailure>());
    });
  });
}
