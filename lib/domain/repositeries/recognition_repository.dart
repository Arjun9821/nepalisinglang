import 'package:camera/camera.dart';

import '../../data/models/recognition_result.dart';

/// Domain-layer contract for turning a live camera frame into a
/// [RecognitionResult], implemented by both the offline and online pipelines.
/// Frames are passed as the raw [CameraImage] so each implementation can do its
/// own conversion off the main isolate -- see `RecognitionIsolate` for why that
/// matters offline.
abstract class RecognitionRepository {
  /// Prepares the underlying pipeline (loads model / opens connection).
  Future<void> initialize();

  /// Runs recognition on a single live camera frame. [sensorOrientation] is the
  /// camera's mounted sensor angle (0/90/180/270), needed to rotate it upright.
  Future<RecognitionResult> recognizeFrame(
    CameraImage image,
    int sensorOrientation,
  );

  /// Releases any held resources (model interpreter / socket / client).
  Future<void> dispose();
}
