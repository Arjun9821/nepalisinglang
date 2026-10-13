import 'package:camera/camera.dart';

import '../../domain/repositeries/recognition_repository.dart';
import '../../services/offline_model/offline_recognition_service.dart';
import '../models/recognition_result.dart';

/// Adapts [OfflineRecognitionService] to [RecognitionRepository] so the
/// presentation layer never talks to the TFLite service directly.
class OfflineRecognitionRepository implements RecognitionRepository {
  final OfflineRecognitionService _service;

  OfflineRecognitionRepository({OfflineRecognitionService? service})
      : _service = service ?? OfflineRecognitionService();

  @override
  Future<void> initialize() => _service.initializeModel();

  @override
  Future<RecognitionResult> recognizeFrame(
    CameraImage image,
    int sensorOrientation,
  ) {
    return _service.recognizeCameraImage(image, sensorOrientation);
  }

  @override
  Future<void> dispose() => _service.dispose();
}
