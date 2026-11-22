import 'package:meta/meta.dart';

/// Abaca fiber supplier for inbound stock receipts (`suppliers` table / collection).
///
/// Relationships (`ON DELETE RESTRICT` + [isActive] archival):
/// - `1:N` parent of `stock_ins` (`stock_ins.supplier_id`). Deleting a supplier
///   that still has receipts is rejected (`ConflictFailure`) to protect
///   inbound inventory history.
///
/// Firestore note: DTO stores lowercase `search_tokens` for partial name search
/// and syncs denormalized `supplier_name` onto recent/matching `stock_ins`.
@immutable
final class Supplier {
  const Supplier({
    required this.id,
    required this.firstName,
    this.middleName,
    required this.lastName,
    this.contactNumber,
    this.address,
    this.isActive = true,
    required this.createdAt,
    required this.updatedAt,
  });

  /// Primary key (`supplier_id`).
  final String id;
  final String firstName;
  final String? middleName;
  final String lastName;
  final String? contactNumber;

  /// Street/barangay address (validated up to 500 chars; `VARCHAR(500)` in SQL).
  final String? address;
  final bool isActive;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Computed full display name (`firstName [middleName] lastName`).
  String get fullName {
    final middle = middleName?.trim();
    if (middle == null || middle.isEmpty) {
      return '$firstName $lastName'.trim();
    }
    return '$firstName $middle $lastName'.trim();
  }

  Supplier copyWith({
    String? id,
    String? firstName,
    String? middleName,
    bool clearMiddleName = false,
    String? lastName,
    String? contactNumber,
    bool clearContactNumber = false,
    String? address,
    bool clearAddress = false,
    bool? isActive,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) =>
      Supplier(
        id: id ?? this.id,
        firstName: firstName ?? this.firstName,
        middleName: clearMiddleName ? null : (middleName ?? this.middleName),
        lastName: lastName ?? this.lastName,
        contactNumber:
            clearContactNumber ? null : (contactNumber ?? this.contactNumber),
        address: clearAddress ? null : (address ?? this.address),
        isActive: isActive ?? this.isActive,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Supplier &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          firstName == other.firstName &&
          middleName == other.middleName &&
          lastName == other.lastName &&
          contactNumber == other.contactNumber &&
          address == other.address &&
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
        contactNumber,
        address,
        isActive,
        createdAt,
        updatedAt,
      );

  @override
  String toString() =>
      'Supplier(id: $id, fullName: $fullName, isActive: $isActive)';
}
