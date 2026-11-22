import 'package:cloud_firestore/cloud_firestore.dart' hide Order, ListEquality;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:get_it/get_it.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../features/audit/data/fake/in_memory_audit_repository.dart';
import '../../features/audit/data/firestore/firestore_audit_repository.dart';
import '../../features/audit/data/supabase/supabase_audit_repository.dart';
import '../../features/audit/domain/repositories/audit_repository.dart';
import '../../features/auth/data/fake/in_memory_auth_repository.dart';
import '../../features/auth/data/fake/in_memory_employee_repository.dart';
import '../../features/auth/data/firestore/firestore_auth_repository.dart';
import '../../features/auth/data/firestore/firestore_employee_repository.dart';
import '../../features/auth/data/supabase/supabase_auth_repository.dart';
import '../../features/auth/data/supabase/supabase_employee_repository.dart';
import '../../features/auth/domain/repositories/auth_repository.dart';
import '../../features/auth/domain/repositories/employee_repository.dart';
import '../../features/finance/data/fake/in_memory_expense_repository.dart';
import '../../features/finance/data/fake/in_memory_payment_repository.dart';
import '../../features/finance/data/firestore/firestore_expense_repository.dart';
import '../../features/finance/data/firestore/firestore_payment_repository.dart';
import '../../features/finance/data/supabase/supabase_expense_repository.dart';
import '../../features/finance/data/supabase/supabase_payment_repository.dart';
import '../../features/finance/domain/repositories/expense_repository.dart';
import '../../features/finance/domain/repositories/payment_repository.dart';
import '../../features/inventory/data/fake/in_memory_inventory_repository.dart';
import '../../features/inventory/data/fake/in_memory_stock_in_repository.dart';
import '../../features/inventory/data/fake/in_memory_stock_out_repository.dart';
import '../../features/inventory/data/firestore/firestore_inventory_repository.dart';
import '../../features/inventory/data/firestore/firestore_stock_in_repository.dart';
import '../../features/inventory/data/firestore/firestore_stock_out_repository.dart';
import '../../features/inventory/data/supabase/supabase_inventory_repository.dart';
import '../../features/inventory/data/supabase/supabase_stock_in_repository.dart';
import '../../features/inventory/data/supabase/supabase_stock_out_repository.dart';
import '../../features/inventory/domain/repositories/inventory_repository.dart';
import '../../features/inventory/domain/repositories/stock_in_repository.dart';
import '../../features/inventory/domain/repositories/stock_out_repository.dart';
import '../../features/orders/data/fake/in_memory_delivery_repository.dart';
import '../../features/orders/data/fake/in_memory_order_repository.dart';
import '../../features/orders/data/firestore/firestore_delivery_repository.dart';
import '../../features/orders/data/firestore/firestore_order_repository.dart';
import '../../features/orders/data/supabase/supabase_delivery_repository.dart';
import '../../features/orders/data/supabase/supabase_order_repository.dart';
import '../../features/orders/domain/repositories/delivery_repository.dart';
import '../../features/orders/domain/repositories/order_repository.dart';
import '../../features/partners/data/fake/in_memory_customer_repository.dart';
import '../../features/partners/data/fake/in_memory_supplier_repository.dart';
import '../../features/partners/data/firestore/firestore_customer_repository.dart';
import '../../features/partners/data/firestore/firestore_supplier_repository.dart';
import '../../features/partners/data/supabase/supabase_customer_repository.dart';
import '../../features/partners/data/supabase/supabase_supplier_repository.dart';
import '../../features/partners/domain/repositories/customer_repository.dart';
import '../../features/partners/domain/repositories/supplier_repository.dart';
import '../config/backend_config.dart';
import '../data/fake/in_memory_database.dart';

/// Global service locator exposing all 12 pure domain repository abstractions.
final GetIt sl = GetIt.instance;

/// Registers the concrete repository implementations matching [backend] into
/// [locator] (defaults to [sl]).
///
/// Flipping [AppBackendConfig.selectedBackend] (or passing [backend]) switches
/// every repository between PostgreSQL/Supabase and Cloud Firestore with zero
/// changes to domain entities, view models, or UI.
Future<void> configureDependencies({
  BackendType backend = AppBackendConfig.selectedBackend,
  GetIt? locator,
  SupabaseClient? supabaseClient,
  String? supabaseUrl,
  String? supabasePublishableKey,
  FirebaseFirestore? firestore,
  FirebaseAuth? firebaseAuth,
  InMemoryDatabase? inMemoryDatabase,
}) async {
  final target = locator ?? sl;
  await target.reset();

  switch (backend) {
    case BackendType.supabase:
      final client = supabaseClient ?? Supabase.instance.client;
      final effectiveUrl =
          supabaseUrl ?? const String.fromEnvironment('SUPABASE_URL');
      final effectiveKey = supabasePublishableKey ??
          const String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');

      target
        ..registerLazySingleton<AuditRepository>(
          () => SupabaseAuditRepository(client),
        )
        ..registerLazySingleton<AuthRepository>(
          () => SupabaseAuthRepository(
            client,
            supabaseUrl: effectiveUrl.isEmpty ? null : effectiveUrl,
            supabasePublishableKey: effectiveKey.isEmpty ? null : effectiveKey,
          ),
        )
        ..registerLazySingleton<EmployeeRepository>(
          () => SupabaseEmployeeRepository(client),
        )
        ..registerLazySingleton<SupplierRepository>(
          () => SupabaseSupplierRepository(client),
        )
        ..registerLazySingleton<CustomerRepository>(
          () => SupabaseCustomerRepository(client),
        )
        ..registerLazySingleton<InventoryRepository>(
          () => SupabaseInventoryRepository(client),
        )
        ..registerLazySingleton<StockInRepository>(
          () => SupabaseStockInRepository(client),
        )
        ..registerLazySingleton<StockOutRepository>(
          () => SupabaseStockOutRepository(client),
        )
        ..registerLazySingleton<OrderRepository>(
          () => SupabaseOrderRepository(client),
        )
        ..registerLazySingleton<DeliveryRepository>(
          () => SupabaseDeliveryRepository(client),
        )
        ..registerLazySingleton<PaymentRepository>(
          () => SupabasePaymentRepository(client),
        )
        ..registerLazySingleton<ExpenseRepository>(
          () => SupabaseExpenseRepository(client),
        );

    case BackendType.firebase:
      final db = firestore ?? FirebaseFirestore.instance;
      final auth = firebaseAuth ?? FirebaseAuth.instance;

      target
        ..registerLazySingleton<AuditRepository>(
          () => FirestoreAuditRepository(db),
        )
        ..registerLazySingleton<AuthRepository>(
          () => FirestoreAuthRepository(auth, db),
        )
        ..registerLazySingleton<EmployeeRepository>(
          () => FirestoreEmployeeRepository(db),
        )
        ..registerLazySingleton<SupplierRepository>(
          () => FirestoreSupplierRepository(db),
        )
        ..registerLazySingleton<CustomerRepository>(
          () => FirestoreCustomerRepository(db),
        )
        ..registerLazySingleton<InventoryRepository>(
          () => FirestoreInventoryRepository(db),
        )
        ..registerLazySingleton<StockInRepository>(
          () => FirestoreStockInRepository(db),
        )
        ..registerLazySingleton<StockOutRepository>(
          () => FirestoreStockOutRepository(db),
        )
        ..registerLazySingleton<OrderRepository>(
          () => FirestoreOrderRepository(db),
        )
        ..registerLazySingleton<DeliveryRepository>(
          () => FirestoreDeliveryRepository(db),
        )
        ..registerLazySingleton<PaymentRepository>(
          () => FirestorePaymentRepository(db),
        )
        ..registerLazySingleton<ExpenseRepository>(
          () => FirestoreExpenseRepository(db),
        );

    case BackendType.inMemory:
      final db = inMemoryDatabase ?? InMemoryDatabase();

      target
        ..registerSingleton<InMemoryDatabase>(db)
        ..registerLazySingleton<AuditRepository>(
          () => InMemoryAuditRepository(db),
        )
        ..registerLazySingleton<AuthRepository>(
          () => InMemoryAuthRepository(db),
        )
        ..registerLazySingleton<EmployeeRepository>(
          () => InMemoryEmployeeRepository(db),
        )
        ..registerLazySingleton<SupplierRepository>(
          () => InMemorySupplierRepository(db),
        )
        ..registerLazySingleton<CustomerRepository>(
          () => InMemoryCustomerRepository(db),
        )
        ..registerLazySingleton<InventoryRepository>(
          () => InMemoryInventoryRepository(db),
        )
        ..registerLazySingleton<StockInRepository>(
          () => InMemoryStockInRepository(db),
        )
        ..registerLazySingleton<StockOutRepository>(
          () => InMemoryStockOutRepository(db),
        )
        ..registerLazySingleton<OrderRepository>(
          () => InMemoryOrderRepository(db),
        )
        ..registerLazySingleton<DeliveryRepository>(
          () => InMemoryDeliveryRepository(db),
        )
        ..registerLazySingleton<PaymentRepository>(
          () => InMemoryPaymentRepository(db),
        )
        ..registerLazySingleton<ExpenseRepository>(
          () => InMemoryExpenseRepository(db),
        );
  }
}
