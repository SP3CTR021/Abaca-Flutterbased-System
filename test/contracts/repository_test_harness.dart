import 'package:abaca_system/features/audit/domain/audit_domain.dart';
import 'package:abaca_system/features/auth/domain/auth_domain.dart';
import 'package:abaca_system/features/finance/domain/finance_domain.dart';
import 'package:abaca_system/features/inventory/domain/inventory_domain.dart';
import 'package:abaca_system/features/orders/domain/orders_domain.dart';
import 'package:abaca_system/features/partners/domain/partners_domain.dart';

/// Factory creating a fresh, isolated [RepositoryTestHarness] for each test.
typedef HarnessFactory = Future<RepositoryTestHarness> Function();

/// Backend-agnostic bundle of all 12 domain repository interfaces used by
/// every shared contract test suite.
final class RepositoryTestHarness {
  RepositoryTestHarness({
    required this.auditRepository,
    required this.authRepository,
    required this.employeeRepository,
    required this.supplierRepository,
    required this.customerRepository,
    required this.inventoryRepository,
    required this.stockInRepository,
    required this.stockOutRepository,
    required this.orderRepository,
    required this.deliveryRepository,
    required this.paymentRepository,
    required this.expenseRepository,
    this.onDispose,
  });

  final AuditRepository auditRepository;
  final AuthRepository authRepository;
  final EmployeeRepository employeeRepository;
  final SupplierRepository supplierRepository;
  final CustomerRepository customerRepository;
  final InventoryRepository inventoryRepository;
  final StockInRepository stockInRepository;
  final StockOutRepository stockOutRepository;
  final OrderRepository orderRepository;
  final DeliveryRepository deliveryRepository;
  final PaymentRepository paymentRepository;
  final ExpenseRepository expenseRepository;
  final Future<void> Function()? onDispose;

  Future<void> dispose() async {
    await onDispose?.call();
  }

  /// Registers and returns an active employee through [authRepository].
  Future<Employee> seedEmployee({
    String firstName = 'Ana',
    String? middleName,
    String lastName = 'Belena',
    String email = 'ana.belena@abaca.test',
    String password = 'password123',
    EmployeeRole role = EmployeeRole.manager,
    String? actorEmployeeId,
  }) async {
    final res = await authRepository.registerEmployee(
      firstName: firstName,
      middleName: middleName,
      lastName: lastName,
      email: email,
      password: password,
      role: role,
      actorEmployeeId: actorEmployeeId,
    );
    return res.getOrThrow();
  }

  /// Creates and returns a [Supplier] through [supplierRepository].
  Future<Supplier> seedSupplier({
    String firstName = 'Mario',
    String? middleName,
    String lastName = 'Reyes',
    String? contactNumber = '09171234567',
    String? address = 'Albay',
    String? actorEmployeeId,
  }) async {
    final res = await supplierRepository.createSupplier(
      firstName: firstName,
      middleName: middleName,
      lastName: lastName,
      contactNumber: contactNumber,
      address: address,
      actorEmployeeId: actorEmployeeId,
    );
    return res.getOrThrow();
  }

  /// Creates and returns a [Customer] through [customerRepository].
  Future<Customer> seedCustomer({
    String firstName = 'Juan',
    String? middleName,
    String lastName = 'Cruz',
    String? contactNumber = '09187654321',
    String? address = 'Sorsogon',
    String? actorEmployeeId,
  }) async {
    final res = await customerRepository.createCustomer(
      firstName: firstName,
      middleName: middleName,
      lastName: lastName,
      contactNumber: contactNumber,
      address: address,
      actorEmployeeId: actorEmployeeId,
    );
    return res.getOrThrow();
  }

  /// Creates and returns an [Inventory] fiber grade through [inventoryRepository].
  Future<Inventory> seedGrade({
    String abacaType = 'S2',
    String? description = 'Grade S2',
    double initialStockKg = 0.0,
    double minStockThresholdKg = 25.0,
    String? actorEmployeeId,
  }) async {
    final res = await inventoryRepository.createGrade(
      abacaType: abacaType,
      description: description,
      initialStockKg: initialStockKg,
      minStockThresholdKg: minStockThresholdKg,
      actorEmployeeId: actorEmployeeId,
    );
    return res.getOrThrow();
  }
}
