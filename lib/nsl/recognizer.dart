import 'dart:collection';

import 'package:hand_landmarker/hand_landmarker.dart';

import '../data/models/recognition_mode.dart';
import '../data/models/recognition_result.dart';
import 'features.dart';
import 'model.dart';

/// Whether raw landmarks get horizontally mirrored before feature extraction.
///
/// MediaPipe returns raw sensor-space landmarks and the plugin mirrors nothing,
/// so the front sensor delivers a right hand with the geometry of a left one,
/// and [Features.compute] is not mirror-invariant. A mismatch shows up as:
/// symmetric handshapes work, asymmetric ones only with the opposite hand, some
/// only rotated. The parity gate replays stored landmarks, so it cannot catch it.
enum MirrorMode {
  /// Decide from the active lens. See [Recognizer.mirrorApplied] for the rule.
  auto,

  /// Always mirror, whatever the lens. Debug override.
  on,

  /// Never mirror. Debug override.
  off,
}

extension MirrorModeLabel on MirrorMode {
  String get label => switch (this) {
        MirrorMode.auto => 'Auto',
        MirrorMode.on => 'On',
        MirrorMode.off => 'Off',
      };
}

/// Why a frame produced no usable classification. Debug-surface only, and not a
/// field on [RecognitionResult]: that type is shared with the image and online
/// paths, which have no notion of these cases.
enum SkipReason {
  /// The frame classified normally.
  none,

  /// MediaPipe returned no hand at all.
  noHand,

  /// MediaPipe found a hand, but [Features.compute] rejected it -- the
  /// wrist-to-middle-MCP distance was ~0, so the landmarks cannot be scaled.
  degenerateHand,
}

extension SkipReasonLabel on SkipReason {
  String get label => switch (this) {
        SkipReason.none => 'OK',
        SkipReason.noHand => 'No hand detected',
        SkipReason.degenerateHand => 'Degenerate hand (zero scale)',
      };
}

/// Turns MediaPipe hand landmarks into a [RecognitionResult]. Inference only --
/// `TemporalStabilizer` and `SentenceBufferManager` own the confidence gate and
/// stability counter that section 7 of the spec sketches here.
///
/// [recognize] never returns null: a null would let the screen skip
/// `SentencePipelineController.ingest`, leaving idle detection dependent on the
/// controller's ticker alone. So a low-confidence prediction comes back with its
/// real label and is gated downstream, and only a frame with no usable hand
/// comes back as [RecognitionResult.empty].
class Recognizer {
  Recognizer(this.model, {int detectionWindow = 60})
      : _detectionWindow = detectionWindow;

  final NslModel model;

  /// How many recent frames the rolling [detectionRate] covers.
  final int _detectionWindow;

  // Debug overlay surface, read directly rather than through state: these change
  // every frame and must not rebuild the sentence panel.

  /// Top-1 label for the most recent classified frame, or null if none yet.
  String? topLabel;

  /// Softmax confidence for [topLabel], in `[0, 1]`.
  double topConf = 0;

  /// Why the most recent frame produced nothing, if it produced nothing.
  SkipReason lastSkipReason = SkipReason.none;

  // Handedness normalisation, see [MirrorMode].

  /// Manual override for the mirroring rule, driven by the debug screen.
  MirrorMode mirrorMode = MirrorMode.auto;

  /// Whether the front lens is open. Set by the screen that owns the camera.
  bool isFrontLens = false;

  /// Whether the next frame will be mirrored. [MirrorMode.auto] mirrors on the
  /// front lens only. Provisional until confirmed live on both lenses -- if the
  /// training data came through a mirrored preview, the rule inverts.
  bool get mirrorApplied => switch (mirrorMode) {
        MirrorMode.on => true,
        MirrorMode.off => false,
        MirrorMode.auto => isFrontLens,
      };

  /// The most recent raw landmarks, before any feature transform. Diagnostics
  /// only: the parity gate validates nothing upstream of [Features.compute], so
  /// these tell you whether the camera path matches what training saw.
  List<List<double>>? lastRawLandmarks;

  final Queue<bool> _detections = Queue<bool>();
  int _detectedCount = 0;

  /// Fraction of the last [_detectionWindow] frames in which MediaPipe returned
  /// a hand -- detection, not successful classification (a degenerate hand
  /// counts here, and shows up in [lastSkipReason]).
  ///
  /// The first number to check when live accuracy disappoints: high with poor
  /// accuracy points at the classifier or MediaPipe drift from the 0.10.14 used
  /// in training, low at framing, lighting or distance.
  double get detectionRate =>
      _detections.isEmpty ? 0 : _detectedCount / _detections.length;

  /// How many frames [detectionRate] covers, so the UI can avoid presenting an
  /// unconverged number as meaningful.
  int get detectionSamples => _detections.length;

  /// Rolling window rather than since-launch, so the figure tracks current
  /// conditions.
  void _recordDetection(bool detected) {
    _detections.addLast(detected);
    if (detected) _detectedCount++;
    while (_detections.length > _detectionWindow) {
      if (_detections.removeFirst()) _detectedCount--;
    }
  }

  /// Classifies one landmark event. Never returns null -- see the class doc.
  RecognitionResult recognize(List<Hand> hands) {
    if (hands.isEmpty) {
      _recordDetection(false);
      lastSkipReason = SkipReason.noHand;
      topLabel = null;
      topConf = 0;
      return RecognitionResult.empty(RecognitionMode.offline);
    }

    _recordDetection(true);

    final raw = [
      for (final l in hands.first.landmarks) <double>[l.x, l.y, l.z],
    ];

    // Mirror at the LANDMARK level: features 63-77 are distances and angles,
    // not sign flips of their unmirrored counterparts. x is normalised to
    // [0, 1], so the reflection is about x = 0.5.
    if (mirrorApplied) {
      for (final p in raw) {
        p[0] = 1.0 - p[0];
      }
    }
    lastRawLandmarks = raw;
    final f = Features.compute(raw);
    if (f == null) {
      lastSkipReason = SkipReason.degenerateHand;
      topLabel = null;
      topConf = 0;
      return RecognitionResult.empty(RecognitionMode.offline);
    }

    // The graph has no softmax layer, so infer() returns logits.
    final probabilities =
        NslModel.softmax(model.infer(Features.standardise(f, model.mu, model.sd)));
    var best = 0;
    for (var i = 1; i < probabilities.length; i++) {
      if (probabilities[i] > probabilities[best]) best = i;
    }

    lastSkipReason = SkipReason.none;
    topLabel = model.labels[best];
    topConf = probabilities[best];

    // Ungated on purpose: TemporalStabilizer owns the confidence threshold.
    return RecognitionResult(
      recognizedText: model.labels[best],
      confidence: probabilities[best],
      timestamp: DateTime.now(),
      mode: RecognitionMode.offline,
      handDetected: true,
    );
  }

  /// Clears the overlay figures, e.g. when the screen releases the camera.
  void reset() {
    topLabel = null;
    topConf = 0;
    lastSkipReason = SkipReason.none;
    lastRawLandmarks = null;
    _detections.clear();
    _detectedCount = 0;
  }
}
