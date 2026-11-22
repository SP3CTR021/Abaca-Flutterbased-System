import 'package:cloud_firestore/cloud_firestore.dart' hide Order, ListEquality;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'backend_config.dart';

/// Initializes the selected backend SDK ([BackendType.supabase] or
/// [BackendType.firebase]) before registering DI repositories.
abstract final class BackendInitializer {
  static Future<void> initialize([
    AppBackendConfig config = const AppBackendConfig(),
  ]) async {
    WidgetsFlutterBinding.ensureInitialized();

    switch (config.backend) {
      case BackendType.supabase:
        if (config.supabase.url.isEmpty ||
            config.supabase.publishableKey.isEmpty) {
          throw StateError(
            'Missing SUPABASE_URL or SUPABASE_PUBLISHABLE_KEY. '
            'Provide them via --dart-define or SupabaseBackendConfig.',
          );
        }
        await Supabase.initialize(
          url: config.supabase.url,
          publishableKey: config.supabase.publishableKey,
        );
      case BackendType.firebase:
        if (Firebase.apps.isEmpty) {
          await Firebase.initializeApp(options: config.firebase.options);
        } else {
          Firebase.app();
        }
        if (config.firebase.useEmulators) {
          FirebaseFirestore.instance.useFirestoreEmulator(
            config.firebase.emulatorHost,
            config.firebase.firestorePort,
          );
          await FirebaseAuth.instance.useAuthEmulator(
            config.firebase.emulatorHost,
            config.firebase.authPort,
          );
        }
      case BackendType.inMemory:
        break;
    }
  }
}
