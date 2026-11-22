import 'package:cloud_firestore/cloud_firestore.dart' hide Order, ListEquality;

import '../../../../core/data/firestore/firestore_helpers.dart';
import '../../domain/entities/customer.dart';

/// Cloud Firestore DTO mapper for `customers/{customerId}`.
///
/// Stores `full_name` and `search_tokens` so partial-name search works in
/// Firestore without leaking backend fields into [Customer].
abstract final class CustomerFirestoreDto {
  static Customer fromFirestore(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data()!;
    return Customer(
      id: doc.id,
      firstName: data['first_name'] as String,
      middleName: data['middle_name'] as String?,
      lastName: data['last_name'] as String,
      contactNumber: data['contact_number'] as String?,
      address: data['address'] as String?,
      isActive: (data['is_active'] as bool?) ?? true,
      createdAt: FirestoreHelpers.fromTimestamp(data['created_at']),
      updatedAt: FirestoreHelpers.fromTimestamp(data['updated_at']),
    );
  }

  static Map<String, dynamic> toFirestore({
    required String firstName,
    String? middleName,
    required String lastName,
    String? contactNumber,
    String? address,
    required bool isActive,
    required DateTime createdAt,
    required DateTime updatedAt,
  }) {
    final trimmedFirst = firstName.trim();
    final trimmedMiddle = _trimOrNull(middleName);
    final trimmedLast = lastName.trim();
    final trimmedContact = _trimOrNull(contactNumber);
    final trimmedAddress = _trimOrNull(address);

    return <String, dynamic>{
      'first_name': trimmedFirst,
      'middle_name': trimmedMiddle,
      'last_name': trimmedLast,
      'full_name': FirestoreHelpers.formatFullName(
        firstName: trimmedFirst,
        middleName: trimmedMiddle,
        lastName: trimmedLast,
      ),
      'contact_number': trimmedContact,
      'address': trimmedAddress,
      'is_active': isActive,
      'search_tokens': FirestoreHelpers.buildSearchTokens(<String?>[
        trimmedFirst,
        trimmedMiddle,
        trimmedLast,
        trimmedContact,
      ]),
      'created_at': FirestoreHelpers.toTimestamp(createdAt),
      'updated_at': FirestoreHelpers.toTimestamp(updatedAt),
    };
  }

  static String? _trimOrNull(String? value) {
    final trimmed = value?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }
}
