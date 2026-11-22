import 'package:meta/meta.dart';

import 'employee_role.dart';

/// Authenticated staff member (`employees` table / collection).
///
/// Auth credentials (`password`, sessions) live in Supabase Auth / Firebase Auth
/// rather than the employee profile record. [id] maps 1:1 to `auth.users.id` /
/// `FirebaseAuth.currentUser.uid` (`employee_id`).
///
/// Relationships (`ON DELETE RESTRICT` + [isActive] archival):
/// - `1:N` parent of `orders`, `stock_ins`, `stock_outs`, `deliveries`, `expenses`,
///   and `payments` (added for payment accountability).
/// - `1:N` nullable actor (`ON DELETE SET NULL`) on `activity_logs`.
@immutable
final class Employee {
  const Employee({
    required this.id,
    required this.firstName,
    this.middleName,
    required this.lastName,
    required this.email,
    required this.role,
    this.isActive = true,
    required this.createdAt,
    required this.updatedAt,
  });

  /// Primary key (`employee_id`) matching the backend Auth UID.
  final String id;
  final String firstName;
  final String? middleName;
  final String lastName;
  final String email;
  final EmployeeRole role;
  final bool isActive;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Full formatted name (`firstName [middleName] lastName`).
  String get fullName {
    final middle = middleName?.trim();
    if (middle == null || middle.isEmpty) {
      return '$firstName $lastName'.trim();
    }
    return '$firstName $middle $lastName'.trim();
  }

  Employee copyWith({
    String? id,
    String? firstName,
    String? middleName,
    bool clearMiddleName = false,
    String? lastName,
    String? email,
    EmployeeRole? role,
    bool? isActive,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) =>
      Employee(
        id: id ?? this.id,
        firstName: firstName ?? this.firstName,
        middleName: clearMiddleName ? null : (middleName ?? this.middleName),
        lastName: lastName ?? this.lastName,
        email: email ?? this.email,
        role: role ?? this.role,
        isActive: isActive ?? this.isActive,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Employee &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          firstName == other.firstName &&
          middleName == other.middleName &&
          lastName == other.lastName &&
          email == other.email &&
          role == other.role &&
          isActive == other.isActive &&
          createdAt == other.createdAt &&
          updatedAt == other.updatedAt;

  @override
  int get hashCode => Object.hash(
        runtimeType,
        id,
        firstName,
        middleName,
        lastName,
        email,
        role,
        isActive,
        createdAt,
        updatedAt,
      );

  @override
  String toString() =>
      'Employee(id: $id, fullName: $fullName, email: $email, role: ${role.dbValue}, isActive: $isActive)';
}
