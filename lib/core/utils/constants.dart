/// App-wide constant values: copy and layout in one place.
class AppConstants {
  AppConstants._();

  // --- Branding / copy ---
  static const String appName = 'Nepali Sign Language Recognition';
  static const String appShortDescription =
      'Recognize Nepali Sign Language using AI through Online and '
      'Offline Recognition Modes.';

  static const String waitingForRecognitionText = 'Waiting for recognition...';
  static const String readyToConnectText = 'Ready to connect';
  static const String dummySpeechText =
      'This is a sample voice output. Recognition is not connected yet.';

  // --- Layout ---
  /// Camera preview takes ~60% of the screen height per spec.
  static const double cameraPreviewHeightFraction = 0.6;

  static const double defaultCardRadius = 20;
  static const double defaultPadding = 16;

  // --- Routing ---
  static const String routeHome = '/home';

  // Bottom nav tab indices. Must match RootScaffold's NavigationDestination
  // order -- the Live screen gates camera acquisition on these.
  static const int learnTabIndex = 0;
  static const int homeTabIndex = 1;
  static const int liveTabIndex = 2;
  static const int historyTabIndex = 3;
}