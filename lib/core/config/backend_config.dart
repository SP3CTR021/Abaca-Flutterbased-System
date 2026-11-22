import 'package:firebase_core/firebase_core.dart';
import 'package:meta/meta.dart';

/// Supported remote backend engines.
///
/// Switch the active backend across the entire application by changing
/// [AppBackendConfig.selectedBackend] (one line).
enum BackendType {
  supabase,
  firebase,
  inMemory,
}

/// Configuration for Supabase (`supabase_flutter`).
@immutable
final class SupabaseBackendConfig {
  const SupabaseBackendConfig({
    this.url = const String.fromEnvironment('SUPABASE_URL'),
    this.publishableKey =
        const String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY'),
  });

  final String url;

  /// Supabase project publishable (`anon`) key.
  final String publishableKey;
}

/// Configuration for Firebase (`firebase_core`, `firebase_auth`, `cloud_firestore`).
@immutable
final class FirebaseBackendConfig {
  const FirebaseBackendConfig({
    this.options,
    this.useEmulators = false,
    this.emulatorHost = 'localhost',
    this.firestorePort = 8080,
    this.authPort = 9099,
  });

  final FirebaseOptions? options;
  final bool useEmulators;
  final String emulatorHost;
  final int firestorePort;
  final int authPort;
}

/// Top-level backend selection & connection configuration.
@immutable
final class AppBackendConfig {
  const AppBackendConfig({
    this.backend = selectedBackend,
    this.supabase = const SupabaseBackendConfig(),
    this.firebase = const FirebaseBackendConfig(),
  });

  /// **ONE-LINE BACKEND SWITCH**
  /// Change between `BackendType.supabase` and `BackendType.firebase` here,
  /// with zero changes required to domain entities, repositories, or UI.
  static const BackendType selectedBackend = BackendType.supabase;

  final BackendType backend;
  final SupabaseBackendConfig supabase;
  final FirebaseBackendConfig firebase;
}
