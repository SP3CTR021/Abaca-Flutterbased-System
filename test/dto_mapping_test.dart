import 'package:abaca_system/core/data/firestore/firestore_collections.dart';
import 'package:abaca_system/core/data/firestore/firestore_helpers.dart';
import 'package:abaca_system/core/data/supabase/supabase_helpers.dart';
import 'package:abaca_system/core/errors/app_failure.dart';
import 'package:abaca_system/features/audit/data/supabase/activity_log_supabase_dto.dart';
import 'package:abaca_system/features/audit/domain/audit_domain.dart';
import 'package:abaca_system/features/inventory/data/supabase/stock_in_supabase_dto.dart';
import 'package:abaca_system/features/orders/data/supabase/order_supabase_dto.dart';
import 'package:abaca_system/features/orders/domain/orders_domain.dart';
import 'package:cloud_firestore/cloud_firestore.dart' hide Order, ListEquality;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  group('SupabaseHelpers & DTOs', () {
    test('parses Postgres NUMERIC returned as String or num', () {
      expect(SupabaseHelpers.parseDouble('1250.50'), 1250.5);
      expect(SupabaseHelpers.parseDouble(99.999), 100.0);
      expect(SupabaseHelpers.formatDateOnly(DateTime(2026, 5, 8)), '2026-05-08');
    });

    test('maps PostgrestException & RPC codes to typed AppFailures', () {
      expect(
        SupabaseHelpers.mapError(
          const PostgrestException(message: 'missing', code: 'PGRST116'),
          entityName: 'Order',
          entityId: 'ord-1',
        ),
        isA<NotFoundFailure>(),
      );

      expect(
        SupabaseHelpers.mapError(
          const PostgrestException(message: 'dup', code: '23505'),
        ),
        isA<ConflictFailure>(),
      );

      expect(
        SupabaseHelpers.mapError(
          const PostgrestException(message: 'fk', code: '23503'),
        ),
        isA<ConflictFailure>(),
      );

      expect(
        SupabaseHelpers.mapError(
          const PostgrestException(message: 'rls', code: '42501'),
        ),
        isA<PermissionDeniedFailure>(),
      );

      final stockErr = SupabaseHelpers.mapError(
        const PostgrestException(
          message: 'Insufficient S2 stock',
          code: 'P0003',
          details:
              '{"abaca_type":"S2","available_kg":12.50,"requested_kg":20.00}',
        ),
      );
      expect(stockErr, isA<InsufficientStockFailure>());
      final insufficient = stockErr as InsufficientStockFailure;
      expect(insufficient.abacaType, 'S2');
      expect(insufficient.availableKg, 12.5);
      expect(insufficient.requestedKg, 20.0);

      final transitionErr = SupabaseHelpers.mapError(
        const PostgrestException(
          message: 'Invalid transition',
          code: 'P0004',
          details:
              '{"entity_name":"Delivery","current_state":"delivered","attempted_action":"complete_delivery"}',
        ),
      );
      expect(transitionErr, isA<InvalidStateTransitionFailure>());

      expect(
        SupabaseHelpers.mapError(
          const AuthApiException(
            'Invalid login credentials',
            code: 'invalid_credentials',
          ),
        ),
        isA<UnauthorizedFailure>(),
      );
    });

    test('OrderSupabaseDto handles 1:1 deliveries as both Map and 1-item List',
        () {
      final baseRow = <String, dynamic>{
        'order_id': 'ord-1',
        'customer_id': 'cust-1',
        'employee_id': 'emp-1',
        'inventory_id': 'inv-1',
        'abaca_type': 'S2',
        'order_date': '2026-05-10',
        'quantity_kg': '15.00',
        'price_per_kg': '100.00',
        'total_amount': '1500.00',
        'status': 'stocked',
        'notes': null,
        'created_at': '2026-05-10T08:00:00Z',
        'updated_at': '2026-05-10T08:00:00Z',
        'customers': <String, dynamic>{
          'first_name': 'Juan',
          'middle_name': null,
          'last_name': 'Cruz',
        },
        'employees': <String, dynamic>{
          'first_name': 'Ana',
          'middle_name': 'B',
          'last_name': 'Belena',
        },
        'payments': <dynamic>[],
      };

      final deliveryMap = <String, dynamic>{
        'delivery_id': 'del-1',
        'order_id': 'ord-1',
        'employee_id': 'emp-1',
        'delivery_date': '2026-05-12',
        'delivered_at': null,
        'status': 'pending',
        'notes': null,
        'created_at': '2026-05-10T09:00:00Z',
        'updated_at': '2026-05-10T09:00:00Z',
      };

      final asMap = OrderSupabaseDto.detailsFromSupabase(<String, dynamic>{
        ...baseRow,
        'deliveries': deliveryMap,
      });
      expect(asMap.customerName, 'Juan Cruz');
      expect(asMap.employeeName, 'Ana B Belena');
      expect(asMap.delivery?.id, 'del-1');
      expect(asMap.delivery?.status, DeliveryStatus.pending);

      final asList = OrderSupabaseDto.detailsFromSupabase(<String, dynamic>{
        ...baseRow,
        'deliveries': <dynamic>[deliveryMap],
      });
      expect(asList.delivery?.id, 'del-1');
    });

    test('StockInSupabaseDto & ActivityLogSupabaseDto hydrate joined rows', () {
      final details = StockInSupabaseDto.detailsFromSupabase(<String, dynamic>{
        'stockin_id': 'si-1',
        'order_id': null,
        'supplier_id': 'sup-1',
        'employee_id': 'emp-1',
        'date_received': '2026-05-01',
        'notes': 'Morning batch',
        'created_at': '2026-05-01T08:00:00Z',
        'updated_at': '2026-05-01T08:00:00Z',
        'suppliers': <String, dynamic>{
          'first_name': 'Mario',
          'last_name': 'Reyes',
        },
        'employees': <String, dynamic>{
          'first_name': 'Ana',
          'last_name': 'Belena',
        },
        'stock_in_items': <dynamic>[
          <String, dynamic>{
            'stock_in_item_id': 'item-1',
            'stockin_id': 'si-1',
            'inventory_id': 'inv-1',
            'quantity_kg': '25.00',
            'cost_per_kg': '40.00',
            'created_at': '2026-05-01T08:00:00Z',
            'updated_at': '2026-05-01T08:00:00Z',
            'inventory': <String, dynamic>{'abaca_type': 'S2'},
          },
        ],
      });
      expect(details.supplierName, 'Mario Reyes');
      expect(details.abacaTypeByInventoryId['inv-1'], 'S2');
      expect(details.totalCost, 1000.0);

      final log = ActivityLogSupabaseDto.fromSupabase(<String, dynamic>{
        'activity_log_id': 'log-1',
        'actor_employee_id': 'emp-1',
        'action': 'created',
        'entity_type': 'stock_in',
        'entity_id': 'si-1',
        'description': 'Created receipt',
        'old_values': null,
        'new_values': <String, dynamic>{'qty': 25},
        'created_at': '2026-05-01T08:00:00Z',
      });
      expect(log.action, AuditAction.created);
      expect(log.entityType, AuditEntityType.stockIn);
    });
  });

  group('FirestoreHelpers & Collections', () {
    test('search tokens, date-only Timestamp round-trip, and error mapping', () {
      expect(FirestoreCollections.normalizeLockKey(' S2 Grade '), 's2%20grade');

      final tokens = FirestoreHelpers.buildSearchTokens(<String?>[
        'Juan',
        'Dela Cruz',
        '09171234567',
      ]);
      expect(tokens, containsAll(<String>['ju', 'jua', 'juan', 'de', 'cr', 'cruz']));

      final dateTs = FirestoreHelpers.toDateOnlyTimestamp(
        DateTime(2026, 5, 14, 17, 45),
      );
      expect(dateTs, isA<Timestamp>());
      expect(
        FirestoreHelpers.fromDateOnlyTimestamp(dateTs),
        DateTime(2026, 5, 14),
      );

      expect(
        FirestoreHelpers.mapError(
          FirebaseException(
            plugin: 'cloud_firestore',
            code: 'permission-denied',
            message: 'denied',
          ),
        ),
        isA<PermissionDeniedFailure>(),
      );
      expect(
        FirestoreHelpers.mapError(
          FirebaseAuthException(code: 'wrong-password', message: 'bad'),
        ),
        isA<UnauthorizedFailure>(),
      );
      const customFailure = ConflictFailure(message: 'locked');
      expect(FirestoreHelpers.mapError(customFailure), customFailure);
    });
  });
}
