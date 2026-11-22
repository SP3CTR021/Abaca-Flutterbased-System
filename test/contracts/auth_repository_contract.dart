import 'package:abaca_system/core/errors/app_failure.dart';
import 'package:abaca_system/features/auth/domain/auth_domain.dart';
import 'package:flutter_test/flutter_test.dart';

import 'repository_test_harness.dart';

void runAuthRepositoryContractTests(HarnessFactory createHarness) {
  group('AuthRepository contract', () {
    late RepositoryTestHarness harness;

    setUp(() async {
      harness = await createHarness();
    });

    tearDown(() async {
      await harness.dispose();
    });

    test('registerEmployee, signIn, watchAuthState, and signOut lifecycle',
        () async {
      final registered = await harness.authRepository.registerEmployee(
        firstName: 'Ana',
        lastName: 'Belena',
        email: 'Ana.Belena@Abaca.Test',
        password: 'password123',
        role: EmployeeRole.manager,
      );
      expect(registered.isOk, isTrue);
      final employee = registered.getOrThrow();
      expect(employee.email, 'ana.belena@abaca.test');

      await harness.authRepository.signOut();
      expect((await harness.authRepository.getCurrentEmployee()).getOrThrow(),
          isNull);

      final signedIn = await harness.authRepository.signInWithEmailAndPassword(
        email: 'ana.belena@abaca.test',
        password: 'password123',
      );
      expect(signedIn.isOk, isTrue);
      expect(
        (await harness.authRepository.getCurrentEmployee()).getOrThrow()?.id,
        employee.id,
      );

      final emitted = await harness.authRepository.watchAuthState().first;
      expect(emitted?.id, employee.id);

      await harness.authRepository.signOut();
      expect(await harness.authRepository.watchAuthState().first, isNull);
    });

    test('rejects duplicate email and invalid password', () async {
      await harness.seedEmployee(email: 'dup@abaca.test');

      final duplicate = await harness.authRepository.registerEmployee(
        firstName: 'Other',
        lastName: 'Staff',
        email: 'DUP@abaca.test',
        password: 'password123',
        role: EmployeeRole.warehouseStaff,
      );
      expect(duplicate.failureOrNull, isA<ConflictFailure>());

      final wrongPass = await harness.authRepository.signInWithEmailAndPassword(
        email: 'dup@abaca.test',
        password: 'wrong-password',
      );
      expect(wrongPass.failureOrNull, isA<UnauthorizedFailure>());
    });

    test('preserves active manager session when registering another employee',
        () async {
      final manager = await harness.seedEmployee(
        email: 'manager@abaca.test',
        role: EmployeeRole.manager,
      );
      await harness.authRepository.signInWithEmailAndPassword(
        email: 'manager@abaca.test',
        password: 'password123',
      );

      final staff = await harness.seedEmployee(
        firstName: 'Pedro',
        lastName: 'Warehouse',
        email: 'pedro@abaca.test',
        role: EmployeeRole.warehouseStaff,
        actorEmployeeId: manager.id,
      );
      expect(staff.role, EmployeeRole.warehouseStaff);

      final current =
          (await harness.authRepository.getCurrentEmployee()).getOrThrow();
      expect(current?.id, manager.id);
    });

    test('blocks archived employee from signing in', () async {
      final staff = await harness.seedEmployee(
        email: 'archived@abaca.test',
        role: EmployeeRole.warehouseStaff,
      );
      await harness.authRepository.signOut();
      await harness.employeeRepository.setEmployeeActive(
        id: staff.id,
        isActive: false,
      );

      final signIn = await harness.authRepository.signInWithEmailAndPassword(
        email: 'archived@abaca.test',
        password: 'password123',
      );
      expect(signIn.failureOrNull, isA<PermissionDeniedFailure>());
    });
  });
}
