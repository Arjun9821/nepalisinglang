import 'package:camera/camera.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

import '../../core/config/app_config.dart';
import '../../core/utils/nsl_labels.dart';
import '../../data/models/recognition_mode.dart';
import '../../data/models/recognition_result.dart';
import 'nsl_preprocessor.dart';
import 'recognition_isolate.dart';

/// Wraps the on-device MobileNetV3-Small classifier, trained on
/// silhouette-thresholded grayscale hands.
///
/// Input, verified against the bundled file: `[1, 96, 96, 1]` float32 in
/// `[0, 1]` from [NslPreprocessor]. Single channel -- the exported graph
/// concatenates it to 3 internally, and its own `Rescaling(255.0)` layer maps
/// `[0, 1]` back to the `[0, 255]` that `include_preprocessing=True` expects --
/// so no channel tiling on the Dart side.
///
/// Output: `[1, 36]` float32 **softmax probabilities** (the final Dense layer
/// has `activation="softmax"`), so the max value is directly the confidence.
///
/// All conversion, crop, preprocess and inference work happens on a dedicated
/// [RecognitionIsolate] -- see its class doc for why that is required.
class OfflineRecognitionService {
  Interpreter? _interpreter;
  Interpreter? _palmInterpreter;
  RecognitionIsolate? _recognitionIsolate;

  bool get isInitialized => _recognitionIsolate != null;

  Future<void> initializeModel() async {
    final interpreter = await Interpreter.fromAsset(
      AppConfig.tfliteModelAssetPath,
    );
    // Palm detector -- crops each frame to the hand before classification (see
    // [HandCropper] and [AppConfig.useHandCropStage]).
    final palmInterpreter = await Interpreter.fromAsset(
      AppConfig.palmDetectionModelAssetPath,
    );

    final numClasses = _validateModelContract(interpreter);

    _interpreter = interpreter;
    _palmInterpreter = palmInterpreter;
    _recognitionIsolate = await RecognitionIsolate.spawn(
      interpreterAddress: interpreter.address,
      palmInterpreterAddress: palmInterpreter.address,
      labels: NslLabels.characters,
      numClasses: numClasses,
    );
  }

  /// Checks the bundled .tflite against what [NslPreprocessor] and [NslLabels]
  /// were written for, and returns the class count. Worth failing loudly on: a
  /// different input shape, an int8 build (which wants raw `[0, 255]` uint8) or
  /// a different class count would otherwise misread memory or mislabel every
  /// prediction while still reporting plausible confidences.
  int _validateModelContract(Interpreter interpreter) {
    final inputTensor = interpreter.getInputTensor(0);
    final outputTensor = interpreter.getOutputTensor(0);
    final inputShape = inputTensor.shape;
    final outputShape = outputTensor.shape;

    const expectedInput = [1, NslPreprocessor.inputSize,
        NslPreprocessor.inputSize, 1];
    if (inputShape.length != 4 ||
        inputShape[1] != expectedInput[1] ||
        inputShape[2] != expectedInput[2] ||
        inputShape[3] != expectedInput[3]) {
      throw StateError(
        'Offline model input shape mismatch: expected $expectedInput but '
        '${AppConfig.tfliteModelAssetPath} reports $inputShape. The Dart '
        'preprocessing in NslPreprocessor only produces 96x96x1.',
      );
    }
    if (inputTensor.type != TensorType.float32) {
      throw StateError(
        'Offline model input dtype mismatch: expected float32 in [0, 1] but '
        '${AppConfig.tfliteModelAssetPath} reports ${inputTensor.type}. An '
        'int8/uint8 build needs raw [0, 255] input and output dequantization '
        'instead — see the implementation guide, section 1.',
      );
    }
    if (outputShape.length != 2 || outputShape[1] != NslLabels.count) {
      throw StateError(
        'Offline model output shape mismatch: expected [1, ${NslLabels.count}] '
        'to match NslLabels.characters but got $outputShape.',
      );
    }

    return outputShape[1];
  }

  /// Runs the TFLite model on a single live camera frame.
  Future<RecognitionResult> recognizeCameraImage(
    CameraImage image,
    int sensorOrientation,
  ) async {
    final recognitionIsolate = _recognitionIsolate;
    if (recognitionIsolate == null) {
      throw StateError(
        'OfflineRecognitionService.recognizeCameraImage called before '
        'initializeModel().',
      );
    }

    final outcome = await recognitionIsolate.recognize(image, sensorOrientation);
    if (outcome.error != null) {
      throw StateError(outcome.error!);
    }

    return RecognitionResult(
      recognizedText: outcome.label!,
      confidence: outcome.confidence!,
      timestamp: DateTime.now(),
      mode: RecognitionMode.offline,
      handDetected: outcome.handDetected,
    );
  }

  Future<void> dispose() async {
    _recognitionIsolate?.close();
    _interpreter?.close();
    _palmInterpreter?.close();
    _recognitionIsolate = null;
    _interpreter = null;
    _palmInterpreter = null;
  }
}
