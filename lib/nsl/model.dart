import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

import '../core/config/app_config.dart';
import 'features.dart';

/// The landmark-based NSL classifier: a small MLP over 78 engineered features.
///
/// Verified against the bundled file: input `[1, 78]` float32 of standardised
/// [Features], output `[1, 36]` **raw logits** -- no softmax layer in the graph,
/// so call [softmax] before thresholding.
///
/// Labels, `mu` and `sd` come from `meta.json`, never hardcoded. This model's
/// label order (Devanagari alphabetical) differs from the image classifier's
/// `NslLabels` (a string sort of folder names); reusing that table mislabels
/// almost every class while confidences still look fine.
class NslModel {
  static const String modelAsset = 'assets/nsl.tflite';
  static const String metaAsset = 'assets/meta.json';

  late final Interpreter _it;
  late final List<String> labels;
  late final List<double> mu, sd;
  /// MediaPipe hand-detection confidence for the landmarker. Authoritative,
  /// unlike the advisory fields below: training extracted landmarks at this
  /// value, so changing it shifts the input distribution.
  late final double detConf;

  /// Whether to mirror left hands. False for this model; no handedness flip
  /// may be applied anywhere in the pipeline.
  late final bool mirrorLeft;

  // ADVISORY ONLY. `meta.json`'s thresholds predate any on-device testing, so
  // the gating values come from [AppConfig]; these fields exist only to make a
  // divergence visible (see [_warnOnThresholdDivergence]).

  /// `meta.json`'s `conf_threshold`. Advisory. Use
  /// [AppConfig.landmarkConfidenceThreshold] instead.
  late final double metaConfThreshold;

  /// `meta.json`'s `stable_frames`. Advisory. `TemporalStabilizer` keeps its
  /// own [AppConfig.stableFrameCount] semantics instead.
  late final int metaStableFrames;

  bool _loaded = false;
  bool get isLoaded => _loaded;

  Future<void> load() async {
    _it = await Interpreter.fromAsset(modelAsset);

    final m = jsonDecode(await rootBundle.loadString(metaAsset))
        as Map<String, dynamic>;
    labels = List<String>.from(m['labels'] as List);
    mu = (m['mu'] as List).map((e) => (e as num).toDouble()).toList();
    sd = (m['sd'] as List).map((e) => (e as num).toDouble()).toList();
    detConf = (m['det_conf'] as num).toDouble();
    mirrorLeft = (m['mirror_left'] as bool?) ?? false;
    metaConfThreshold = (m['conf_threshold'] as num).toDouble();
    metaStableFrames = (m['stable_frames'] as num).toInt();

    _validate(m);
    _warnOnThresholdDivergence();
    _loaded = true;
  }

  /// Cross-checks `meta.json` against the interpreter's real tensors. Hard
  /// checks, not `assert`, which is stripped from release builds: a mismatch
  /// otherwise yields an interpreter that is confidently wrong.
  void _validate(Map<String, dynamic> m) {
    final inShape = _it.getInputTensor(0).shape;
    final outShape = _it.getOutputTensor(0).shape;
    final inType = _it.getInputTensor(0).type;

    if (inShape.length != 2 || inShape[1] != Features.dim) {
      throw StateError(
        'Model input shape mismatch: expected [1, ${Features.dim}] but '
        '$modelAsset reports $inShape. Features.compute() only produces '
        '${Features.dim} values.',
      );
    }
    if (inType != TensorType.float32) {
      throw StateError(
        'Model input dtype mismatch: expected float32 but $modelAsset reports '
        '$inType.',
      );
    }
    if (outShape.length != 2 || outShape[1] != labels.length) {
      throw StateError(
        'Model output width ${outShape.length == 2 ? outShape[1] : outShape} '
        'does not match ${labels.length} labels in $metaAsset.',
      );
    }
    final featureDim = (m['feature_dim'] as num?)?.toInt();
    if (featureDim != null && featureDim != Features.dim) {
      throw StateError(
        '$metaAsset declares feature_dim=$featureDim but Features.dim is '
        '${Features.dim}.',
      );
    }
    if (mu.length != Features.dim || sd.length != Features.dim) {
      throw StateError(
        '$metaAsset mu/sd must both be ${Features.dim} long, got '
        '${mu.length}/${sd.length}.',
      );
    }
  }

  /// Logs once if `meta.json`'s advisory thresholds disagree with what is in
  /// force, so it is clear which file the app obeys.
  void _warnOnThresholdDivergence() {
    if (metaConfThreshold != AppConfig.landmarkConfidenceThreshold ||
        metaStableFrames != AppConfig.stableFrameCount) {
      debugPrint(
        '[NSL] meta.json thresholds differ from AppConfig and are IGNORED: '
        'conf_threshold=$metaConfThreshold vs '
        'AppConfig.landmarkConfidenceThreshold='
        '${AppConfig.landmarkConfidenceThreshold}, '
        'stable_frames=$metaStableFrames vs '
        'AppConfig.stableFrameCount=${AppConfig.stableFrameCount}. '
        'AppConfig wins (tuned on device); meta.json values were untested '
        'estimates. Adjust at runtime from the debug screen.',
      );
    }
  }

  /// Runs the model. [std] must already be standardised. Returns **logits**.
  List<double> infer(Float32List std) {
    // tflite_flutter needs a pre-allocated nested list; a flat one produces
    // garbage.
    final out = List.generate(1, (_) => List.filled(labels.length, 0.0));
    _it.run([std], out);
    return List<double>.from(out[0]);
  }

  static List<double> softmax(List<double> z) {
    final mx = z.reduce(math.max);
    final e = z.map((v) => math.exp(v - mx)).toList();
    final s = e.reduce((a, b) => a + b);
    return e.map((v) => v / s).toList();
  }

  void dispose() {
    if (_loaded) _it.close();
    _loaded = false;
  }
}
