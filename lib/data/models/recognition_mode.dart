/// Distinguishes which pipeline produced (or will produce) a result.
enum RecognitionMode {
  offline,
  online;

  String get label {
    switch (this) {
      case RecognitionMode.offline:
        return 'Offline (TFLite)';
      case RecognitionMode.online:
        return 'Online (API)';
    }
  }
}