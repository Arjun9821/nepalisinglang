import 'dart:isolate';

import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

import '../../core/config/app_config.dart';
import '../camera/frame_converter.dart';
import 'hand_crop.dart';
import 'nsl_preprocessor.dart';

/// Runs the full offline pipeline -- YUV/BGRA -> RGB conversion, hand crop, the
/// OpenCV-matched preprocessing chain, TFLite inference -- on a dedicated
/// persistent isolate.
///
/// On the main isolate, that synchronous per-pixel work (tens to hundreds of ms
/// per frame) starved the platform channel delivering the camera stream, which
/// made the native Android camera HAL back up and crash (`CameraDevice` error
/// codes 3/4/5, seen as the preview cycling OPENING/CLOSING/CLOSED). Only the
/// raw [CameraImage] goes in and a tiny result comes back.
class RecognitionIsolate {
  RecognitionIsolate._(this._isolate, this._commandPort);

  final Isolate _isolate;
  final SendPort _commandPort;

  static Future<RecognitionIsolate> spawn({
    required int interpreterAddress,
    required int palmInterpreterAddress,
    required List<String> labels,
    required int numClasses,
  }) async {
    final readyPort = ReceivePort();
    final isolate = await Isolate.spawn(
      _entryPoint,
      readyPort.sendPort,
      debugName: 'OfflineRecognitionIsolate',
    );
    final commandPort = await readyPort.first as SendPort;
    commandPort.send(
      _SetupMessage(
        interpreterAddress,
        palmInterpreterAddress,
        labels,
        numClasses,
      ),
    );
    return RecognitionIsolate._(isolate, commandPort);
  }

  Future<RecognitionOutcome> recognize(CameraImage image, int sensorOrientation) {
    final responsePort = ReceivePort();
    _commandPort.send(
      _FrameMessage(image, sensorOrientation, responsePort.sendPort),
    );
    return responsePort.first.then((value) => value as RecognitionOutcome);
  }

  void close() {
    _commandPort.send(_ShutdownMessage());
    _isolate.kill(priority: Isolate.immediate);
  }

  static void _entryPoint(SendPort readyPort) {
    final commandPort = ReceivePort();
    readyPort.send(commandPort.sendPort);

    late final int address;
    late final List<String> labels;
    late final int numClasses;
    HandCropper? handCropper;

    commandPort.listen((message) {
      if (message is _SetupMessage) {
        address = message.interpreterAddress;
        labels = message.labels;
        numClasses = message.numClasses;
        handCropper = HandCropper.fromAddress(message.palmInterpreterAddress);
      } else if (message is _ShutdownMessage) {
        commandPort.close();
      } else if (message is _FrameMessage) {
        try {
          final rgb = convertCameraImageToImage(
            message.image,
            message.sensorOrientation,
          );

          // Localise the hand first so the preprocessing chain runs over a
          // dataset-style tightly-framed hand instead of the whole room; see
          // [AppConfig.useHandCropStage]. Falls back to the full frame.
          final img.Image classifierInput;
          final bool handDetected;
          if (AppConfig.useHandCropStage) {
            final crop = handCropper?.cropHand(rgb);
            classifierInput = crop ?? rgb;
            // A null crop means the palm detector found nothing above its score
            // threshold. The classifier still runs on the full frame for
            // debugging, but the pipeline must know no hand was localised.
            handDetected = crop != null;
          } else {
            classifierInput = rgb;
            // No detector ran, so "was there a hand?" is unanswerable -- report
            // true rather than starving the stabilizer of active frames.
            handDetected = true;
          }

          // Produces exactly the [1, 96, 96, 1] float32 tensor in [0, 1] the
          // model was trained on.
          final tensor = NslPreprocessor.preprocess(classifierInput);

          // Raw little-endian float32 bytes: tflite_flutter passes a Uint8List
          // straight to TfLiteTensorCopyFromBuffer, skipping both the
          // per-element boxing of a nested List and any input-tensor reshape.
          final input = tensor.buffer.asUint8List(
            tensor.offsetInBytes,
            tensor.lengthInBytes,
          );
          final output = [List<double>.filled(numClasses, 0.0)];
          Interpreter.fromAddress(address).run(input, output);

          // The exported graph ends in a softmax Dense layer, so these are
          // already probabilities -- do NOT apply softmax again.
          final probabilities = output[0];
          var bestIndex = 0;
          for (var i = 1; i < probabilities.length; i++) {
            if (probabilities[i] > probabilities[bestIndex]) bestIndex = i;
          }
          final label = bestIndex < labels.length ? labels[bestIndex] : '?';

          message.responsePort.send(
            RecognitionOutcome(label, probabilities[bestIndex], handDetected),
          );
        } catch (e) {
          message.responsePort.send(RecognitionOutcome.error(e.toString()));
        }
      }
    });
  }
}

class _SetupMessage {
  _SetupMessage(
    this.interpreterAddress,
    this.palmInterpreterAddress,
    this.labels,
    this.numClasses,
  );

  final int interpreterAddress;
  final int palmInterpreterAddress;
  final List<String> labels;
  final int numClasses;
}

class _FrameMessage {
  _FrameMessage(this.image, this.sensorOrientation, this.responsePort);

  final CameraImage image;
  final int sensorOrientation;
  final SendPort responsePort;
}

class _ShutdownMessage {}

class RecognitionOutcome {
  RecognitionOutcome(this.label, this.confidence, this.handDetected)
      : error = null;
  RecognitionOutcome.error(this.error)
      : label = null,
        confidence = null,
        handDetected = false;

  final String? label;
  final double? confidence;
  final String? error;

  /// Whether the palm detector localised a hand in this frame — see
  /// `RecognitionResult.handDetected` for why the sentence pipeline needs it.
  final bool handDetected;
}
