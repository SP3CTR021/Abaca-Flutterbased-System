import 'package:cloud_firestore/cloud_firestore.dart' hide Order, ListEquality;

import '../../../../core/data/firestore/firestore_helpers.dart';
import '../../domain/entities/employee.dart';
import '../../domain/entities/employee_role.dart';

/// Cloud Firestore DTO mapper for `employees/{uid}` documents.
///
/// Stores `email_lower` for case-insensitive uniqueness/lookup queries without
/// leaking backend-only fields into the pure [Employee] domain entity.
abstract final class EmployeeFirestoreDto {
  static Employee fromFirestore(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data()!;
    return Employee(
      id: doc.id,
      firstName: data['first_name'] as String,
      middleName: data['middle_name'] as String?,
      lastName: data['last_name'] as String,
      email: data['email'] as String,
      role: EmployeeRole.fromDb(data['role'] as String),
      isActive: (data['is_active'] as bool?) ?? true,
      createdAt: FirestoreHelpers.fromTimestamp(data['created_at']),
      updatedAt: FirestoreHelpers.fromTimestamp(data['updated_at']),
    );
  }

  static Map<String, dynamic> toFirestore({
    required String firstName,
    String? middleName,
    required String lastName,
    required String email,
    required EmployeeRole role,
    required bool isActive,
    required DateTime createdAt,
    required DateTime updatedAt,
  }) {
    final normalizedEmail = email.trim().toLowerCase();
    final trimmedMiddle = middleName?.trim();
    return <String, dynamic>{
      'first_name': firstName.trim(),
      'middle_name':
          (trimmedMiddle == null || trimmedMiddle.isEmpty) ? null : trimmedMiddle,
      'last_name': lastName.trim(),
      'full_name': FirestoreHelpers.formatFullName(
        firstName: firstName.trim(),
        middleName: trimmedMiddle,
        lastName: lastName.trim(),
      ),
      'email': normalizedEmail,
      'email_lower': normalizedEmail,
      'role': role.dbValue,
      'is_active': isActive,
      'created_at': FirestoreHelpers.toTimestamp(createdAt),
      'updated_at': FirestoreHelpers.toTimestamp(updatedAt),
    };
  }
}
