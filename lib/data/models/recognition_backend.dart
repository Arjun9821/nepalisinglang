/// Which on-device classifier produces predictions. Both are offline (see
/// [RecognitionMode] for on-device vs cloud); the two were built against
/// different input representations and are kept live side by side so they can be
/// compared on real hardware.
enum RecognitionBackend {
  /// MediaPipe hand landmarks -> 78 engineered features -> MLP
  /// (`assets/nsl.tflite`). See `lib/nsl/`.
  landmark,

  /// Palm-crop -> adaptive-threshold silhouette -> MobileNetV3
  /// (`assets/models/nsl_single_fp16.tflite`). See
  /// `lib/services/offline_model/`.
  image,
}

extension RecognitionBackendLabel on RecognitionBackend {
  String get label => switch (this) {
        RecognitionBackend.landmark => 'Landmark (MLP)',
        RecognitionBackend.image => 'Image (MobileNetV3)',
      };
}
