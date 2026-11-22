import 'package:abaca_system/core/errors/app_failure.dart';
import 'package:abaca_system/features/auth/domain/auth_domain.dart';
import 'package:flutter_test/flutter_test.dart';

import 'repository_test_harness.dart';

void runEmployeeRepositoryContractTests(HarnessFactory createHarness) {
  group('EmployeeRepository contract', () {
    late RepositoryTestHarness harness;

    setUp(() async {
      harness = await createHarness();
    });

    tearDown(() async {
      await harness.dispose();
    });

    test('filters by role/isActive, updates profile, and archives/restores',
        () async {
      final mgr = await harness.seedEmployee(
        email: 'mgr@abaca.test',
        role: EmployeeRole.manager,
      );
      final driver = await harness.seedEmployee(
        firstName: 'Leo',
        lastName: 'Driver',
        email: 'driver@abaca.test',
        role: EmployeeRole.deliveryDriver,
      );

      final drivers = (await harness.employeeRepository
              .getEmployees(role: EmployeeRole.deliveryDriver))
          .getOrThrow();
      expect(drivers.map((e) => e.id), <String>[driver.id]);

      final updated = (await harness.employeeRepository.updateEmployee(
        driver.copyWith(middleName: 'B'),
        actorEmployeeId: mgr.id,
      ))
          .getOrThrow();
      expect(updated.fullName, 'Leo B Driver');

      await harness.employeeRepository.setEmployeeActive(
        id: driver.id,
        isActive: false,
        actorEmployeeId: mgr.id,
      );
      final activeOnly =
          (await harness.employeeRepository.getEmployees(isActive: true))
              .getOrThrow();
      expect(activeOnly.map((e) => e.id), <String>[mgr.id]);

      final watched = await harness.employeeRepository
          .watchEmployees(isActive: false)
          .first;
      expect(watched.map((e) => e.id), <String>[driver.id]);
    });

    test('ON DELETE RESTRICT blocks deleting employee referenced by an expense',
        () async {
      final staff = await harness.seedEmployee(email: 'ref@abaca.test');
      (await harness.expenseRepository.createExpense(
        employeeId: staff.id,
        expenseType: 'Fuel',
        amount: 250.0,
        date: DateTime(2026, 5, 10),
      ))
          .getOrThrow();

      final deleteBlocked =
          await harness.employeeRepository.deleteEmployee(staff.id);
      expect(deleteBlocked.failureOrNull, isA<ConflictFailure>());

      final deletable = await harness.seedEmployee(
        email: 'unused@abaca.test',
        lastName: 'Unused',
      );
      final deleteOk =
          await harness.employeeRepository.deleteEmployee(deletable.id);
      expect(deleteOk.isOk, isTrue);
      expect(
        (await harness.employeeRepository.getEmployeeById(deletable.id))
            .failureOrNull,
        isA<NotFoundFailure>(),
      );
    });
  });
}
