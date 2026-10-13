import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/routing/app_router.dart';
import 'core/theme/app_theme.dart';
import 'core/utils/constants.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _bootstrapFirebase();
  runApp(const ProviderScope(child: NepaliSignLanguageApp()));
}

/// Initialises Firebase, but only for the Firebase AI Logic sentence backend.
///
/// Commented out because it needs `lib/firebase_options.dart`, which
/// `flutterfire configure` generates and this repo does not have yet. Failures
/// are swallowed on purpose: recognition works offline, so a Firebase problem
/// must only cost sentence refinement.
Future<void> _bootstrapFirebase() async {
  // if (!AppConfig.useFirebaseAiSynthesizer) return;
  // try {
  //   await Firebase.initializeApp(
  //     options: DefaultFirebaseOptions.currentPlatform,
  //   );
  //   await FirebaseAppCheck.instance.activate(
  //     androidProvider: AndroidProvider.playIntegrity,
  //   );
  // } catch (e) {
  //   debugPrint('[NSL] Firebase init failed, sentence refinement off: $e');
  // }
}

class NepaliSignLanguageApp extends StatelessWidget {
  const NepaliSignLanguageApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: AppConstants.appName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      routerConfig: appRouter,
    );
  }
}
