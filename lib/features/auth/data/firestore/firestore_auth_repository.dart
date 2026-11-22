import 'package:cloud_firestore/cloud_firestore.dart' hide Order, ListEquality;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';

import '../../../../core/data/firestore/firestore_collections.dart';
import '../../../../core/data/firestore/firestore_helpers.dart';
import '../../../../core/data/input_validators.dart';
import '../../../../core/errors/app_failure.dart';
import '../../../../core/result/result.dart';
import '../../../audit/data/firestore/firestore_audit_repository.dart';
import '../../../audit/domain/entities/audit_enums.dart';
import '../../domain/entities/employee.dart';
import '../../domain/entities/employee_role.dart';
import '../../domain/repositories/auth_repository.dart';
import 'employee_firestore_dto.dart';

/// Firebase Auth + Cloud Firestore `employees/{uid}` implementation of [AuthRepository].
final class FirestoreAuthRepository implements AuthRepository {
  FirestoreAuthRepository(this._auth, this._firestore);

  final FirebaseAuth _auth;
  final FirebaseFirestore _firestore;

  CollectionReference<Map<String, dynamic>> get _employees =>
      _firestore.collection(FirestoreCollections.employees);

  @override
  Future<Result<Employee>> signInWithEmailAndPassword({
    required String email,
    required String password,
  }) async {
    final errors = <String, String>{};
    InputValidators.validateEmail(errors, 'email', email);
    InputValidators.requireNonEmpty(errors, 'password', password);
    final validation = InputValidators.toFailure(errors);
    if (validation != null) return Err<Employee>(validation);

    try {
      final credential = await _auth.signInWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
      final user = credential.user;
      if (user == null) {
        return const Err<Employee>(
          UnauthorizedFailure(message: 'Authentication failed.'),
        );
      }

      final doc = await _employees.doc(user.uid).get();
      if (!doc.exists || doc.data() == null) {
        await _auth.signOut();
        return Err<Employee>(
          NotFoundFailure(
            entityName: 'Employee',
            entityId: user.uid,
            message: 'Employee profile for UID ${user.uid} does not exist.',
          ),
        );
      }

      final employee = EmployeeFirestoreDto.fromFirestore(doc);
      if (!employee.isActive) {
        await _auth.signOut();
        return const Err<Employee>(
          PermissionDeniedFailure(
            message: 'This employee account has been archived.',
          ),
        );
      }

      await FirestoreAuditRepository.tryRecordAudit(
        _firestore,
        actorEmployeeId: employee.id,
        action: AuditAction.signedIn,
        entityType: AuditEntityType.auth,
        entityId: employee.id,
        description: '${employee.fullName} signed in.',
      );

      return Ok<Employee>(employee);
    } catch (error) {
      return Err<Employee>(
        FirestoreHelpers.mapError(error, entityName: 'Employee'),
      );
    }
  }

  @override
  Future<Result<void>> signOut() async {
    try {
      final uid = _auth.currentUser?.uid;
      if (uid != null) {
        await FirestoreAuditRepository.tryRecordAudit(
          _firestore,
          actorEmployeeId: uid,
          action: AuditAction.signedOut,
          entityType: AuditEntityType.auth,
          entityId: uid,
          description: 'Employee signed out.',
        );
      }
      await _auth.signOut();
      return const Ok<void>(null);
    } catch (error) {
      return Err<void>(FirestoreHelpers.mapError(error, entityName: 'Auth'));
    }
  }

  @override
  Future<Result<Employee?>> getCurrentEmployee() async {
    try {
      final user = _auth.currentUser;
      if (user == null) return const Ok<Employee?>(null);

      final doc = await _employees.doc(user.uid).get();
      if (!doc.exists || doc.data() == null) return const Ok<Employee?>(null);
      return Ok<Employee?>(EmployeeFirestoreDto.fromFirestore(doc));
    } catch (error) {
      return Err<Employee?>(
        FirestoreHelpers.mapError(error, entityName: 'Employee'),
      );
    }
  }

  @override
  Stream<Employee?> watchAuthState() => _auth.authStateChanges().asyncMap(
        (user) async {
          if (user == null) return null;
          try {
            final doc = await _employees.doc(user.uid).get();
            if (!doc.exists || doc.data() == null) return null;
            return EmployeeFirestoreDto.fromFirestore(doc);
          } catch (_) {
            return null;
          }
        },
      );

  @override
  Future<Result<Employee>> registerEmployee({
    required String firstName,
    String? middleName,
    required String lastName,
    required String email,
    required String password,
    required EmployeeRole role,
    String? actorEmployeeId,
  }) async {
    final errors = <String, String>{};
    InputValidators.requireNonEmpty(errors, 'firstName', firstName);
    InputValidators.requireNonEmpty(errors, 'lastName', lastName);
    InputValidators.validateEmail(errors, 'email', email);
    if (password.length < 6) {
      errors['password'] = 'Password must be at least 6 characters.';
    }
    final validation = InputValidators.toFailure(errors);
    if (validation != null) return Err<Employee>(validation);

    final hasActiveManager = _auth.currentUser != null;
    FirebaseApp? secondaryApp;

    try {
      // Use a short-lived secondary FirebaseApp when a manager creates a new
      // employee account so the manager's current auth session is preserved.
      FirebaseAuth targetAuth = _auth;
      if (hasActiveManager) {
        final appName = 'employee_reg_${DateTime.now().microsecondsSinceEpoch}';
        secondaryApp = await Firebase.initializeApp(
          name: appName,
          options: _auth.app.options,
        );
        targetAuth = FirebaseAuth.instanceFor(app: secondaryApp);
      }

      final normalizedEmail = email.trim().toLowerCase();
      final credential = await targetAuth.createUserWithEmailAndPassword(
        email: normalizedEmail,
        password: password,
      );
      final createdUser = credential.user;
      if (createdUser == null) {
        return const Err<Employee>(
          UnknownFailure(message: 'Failed to create Firebase Auth user.'),
        );
      }

      final now = DateTime.now().toUtc();
      final employee = Employee(
        id: createdUser.uid,
        firstName: firstName.trim(),
        middleName: middleName?.trim().isEmpty == true ? null : middleName?.trim(),
        lastName: lastName.trim(),
        email: normalizedEmail,
        role: role,
        isActive: true,
        createdAt: now,
        updatedAt: now,
      );

      final batch = _firestore.batch();
      batch.set(
        _employees.doc(employee.id),
        EmployeeFirestoreDto.toFirestore(
          firstName: employee.firstName,
          middleName: employee.middleName,
          lastName: employee.lastName,
          email: employee.email,
          role: employee.role,
          isActive: employee.isActive,
          createdAt: now,
          updatedAt: now,
        ),
      );
      FirestoreAuditRepository.setAuditInBatch(
        batch,
        _firestore,
        actorEmployeeId: actorEmployeeId ?? employee.id,
        action: AuditAction.created,
        entityType: AuditEntityType.employee,
        entityId: employee.id,
        description:
            'Registered employee ${employee.fullName} (${employee.role.dbValue}).',
        newValues: <String, Object?>{
          'email': employee.email,
          'role': employee.role.dbValue,
        },
        timestamp: now,
      );
      await batch.commit();

      return Ok<Employee>(employee);
    } catch (error) {
      return Err<Employee>(
        FirestoreHelpers.mapError(error, entityName: 'Employee'),
      );
    } finally {
      if (secondaryApp != null) {
        await secondaryApp.delete();
      }
    }
  }

  @override
  Future<Result<void>> sendPasswordResetEmail(String email) async {
    final errors = <String, String>{};
    InputValidators.validateEmail(errors, 'email', email);
    final validation = InputValidators.toFailure(errors);
    if (validation != null) return Err<void>(validation);

    try {
      await _auth.sendPasswordResetEmail(email: email.trim());
      return const Ok<void>(null);
    } catch (error) {
      return Err<void>(FirestoreHelpers.mapError(error, entityName: 'Auth'));
    }
  }
}
