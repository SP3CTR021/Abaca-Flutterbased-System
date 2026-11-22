import 'package:abaca_system/core/errors/app_failure.dart';
import 'package:abaca_system/features/orders/domain/orders_domain.dart';
import 'package:flutter_test/flutter_test.dart';

import 'repository_test_harness.dart';

void runPaymentRepositoryContractTests(HarnessFactory createHarness) {
  group('PaymentRepository contract', () {
    late RepositoryTestHarness harness;

    setUp(() async {
      harness = await createHarness();
    });

    tearDown(() async {
      await harness.dispose();
    });

    test('blocks payment on pending order, prevents overpayment, and supports void',
        () async {
      final emp = await harness.seedEmployee();
      final cust = await harness.seedCustomer();
      final grade = await harness.seedGrade(abacaType: 'S2', initialStockKg: 50);

      final order = (await harness.orderRepository.createOrder(
        customerId: cust.id,
        employeeId: emp.id,
        inventoryId: grade.id,
        orderDate: DateTime(2026, 5, 1),
        quantityKg: 10,
        pricePerKg: 100, // total = 1000
      ))
          .getOrThrow();

      final pendingPayment = await harness.paymentRepository.recordPayment(
        orderId: order.id,
        employeeId: emp.id,
        amountPaid: 500,
        paymentDate: DateTime(2026, 5, 2),
        paymentMethod: 'Cash',
      );
      expect(
        pendingPayment.failureOrNull,
        isA<InvalidStateTransitionFailure>(),
      );

      (await harness.orderRepository.markOrderStocked(
        orderId: order.id,
        actorEmployeeId: emp.id,
      ))
          .getOrThrow();

      final p1 = (await harness.paymentRepository.recordPayment(
        orderId: order.id,
        employeeId: emp.id,
        amountPaid: 400,
        paymentDate: DateTime(2026, 5, 2),
        paymentMethod: 'GCash',
        referenceNumber: 'GC-1001',
      ))
          .getOrThrow();

      final detailsPartial =
          (await harness.orderRepository.getOrderWithDetails(order.id))
              .getOrThrow();
      expect(detailsPartial.totalPaid, 400.0);
      expect(detailsPartial.remainingBalance, 600.0);
      expect(detailsPartial.paymentStatus, OrderPaymentStatus.partiallyPaid);

      final overpay = await harness.paymentRepository.recordPayment(
        orderId: order.id,
        employeeId: emp.id,
        amountPaid: 650,
        paymentDate: DateTime(2026, 5, 3),
        paymentMethod: 'Cash',
      );
      expect(overpay.failureOrNull, isA<ValidationFailure>());

      (await harness.paymentRepository.recordPayment(
        orderId: order.id,
        employeeId: emp.id,
        amountPaid: 600,
        paymentDate: DateTime(2026, 5, 3),
        paymentMethod: 'Bank Transfer',
      ))
          .getOrThrow();

      final detailsPaid =
          (await harness.orderRepository.getOrderWithDetails(order.id))
              .getOrThrow();
      expect(detailsPaid.paymentStatus, OrderPaymentStatus.paid);
      expect(detailsPaid.remainingBalance, 0.0);

      (await harness.paymentRepository.voidPayment(
        paymentId: p1.id,
        orderId: order.id,
        actorEmployeeId: emp.id,
        reason: 'Duplicate receipt',
      ))
          .getOrThrow();

      final afterVoid =
          (await harness.orderRepository.getOrderWithDetails(order.id))
              .getOrThrow();
      expect(afterVoid.totalPaid, 600.0);
      expect(afterVoid.paymentStatus, OrderPaymentStatus.partiallyPaid);
    });
  });
}
