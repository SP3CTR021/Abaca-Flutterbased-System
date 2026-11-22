import 'package:abaca_system/features/audit/domain/audit_domain.dart';
import 'package:flutter_test/flutter_test.dart';

import 'repository_test_harness.dart';

void runAuditRepositoryContractTests(HarnessFactory createHarness) {
  group('AuditRepository contract', () {
    late RepositoryTestHarness harness;

    setUp(() async {
      harness = await createHarness();
    });

    tearDown(() async {
      await harness.dispose();
    });

    test('appends immutable logs, supports entity/action filtering, and streams newest first',
        () async {
      final emp = await harness.seedEmployee();
      final grade = await harness.seedGrade(abacaType: 'S2');

      (await harness.auditRepository.logActivity(
        actorEmployeeId: emp.id,
        action: AuditAction.updated,
        entityType: AuditEntityType.inventory,
        entityId: grade.id,
        description: 'Manual audit check',
        oldValues: const <String, Object?>{'threshold': 0.0},
        newValues: const <String, Object?>{'threshold': 25.0},
      ))
          .getOrThrow();

      final invLogs = (await harness.auditRepository.getActivityLogs(
        entityType: AuditEntityType.inventory,
        entityId: grade.id,
      ))
          .getOrThrow();
      expect(invLogs.length, greaterThanOrEqualTo(2));
      expect(invLogs.first.action, AuditAction.updated);
      expect(invLogs.first.newValues?['threshold'], 25.0);

      final watched = await harness.auditRepository
          .watchActivityLogs(entityType: AuditEntityType.inventory)
          .first;
      expect(watched.first.entityId, grade.id);
    });
  });
}
