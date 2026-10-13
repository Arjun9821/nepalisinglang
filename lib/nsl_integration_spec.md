# Nepali Sign Language Recognition — Flutter Integration Spec

## 1. What this is

An on-device classifier for 36 Nepali Sign Language characters. It does NOT
use image pixels. It uses MediaPipe hand landmarks (21 points × xyz),
converts them to 78 engineered features, and runs a small MLP.

Pipeline:

    CameraImage
      → MediaPipe HandLandmarker (plugin)   → 21 landmarks
      → Features.compute()                  → 78 raw features
      → standardise with mu/sd              → 78 normalised
      → TFLite MLP                          → 36 logits
      → softmax + confidence gate + temporal smoothing
      → emitted character

Model accuracy: ~94% on a held-out test set (728 images).
Model size: ~200 KB, float32, no quantisation.

## 2. Assets

Place in `assets/`:

| File | Purpose |
|---|---|
| `nsl.tflite` | The classifier. Input `[1,78]` float32, output `[1,36]` float32 logits |
| `meta.json` | Labels, mu, sd, thresholds |
| `parity.json` | 30 test fixtures for verification |

### meta.json shape

    {
      "labels": ["क","ख","ग", ... 36 total],
      "feature_dim": 78,
      "mu": [78 floats],
      "sd": [78 floats],
      "mirror_left": false,
      "det_conf": 0.30,
      "conf_threshold": 0.70,
      "stable_frames": 8
    }

### parity.json shape

    {
      "landmarks": [30][21][3],   // raw MediaPipe output
      "feats":     [30][78],      // expected Features.compute() output
      "logits":    [30][36],      // expected model output
      "true":      [30 strings]   // ground truth labels
    }

IMPORTANT: The model outputs **logits, not probabilities**. There is no
softmax layer in the graph. Apply softmax in Dart before thresholding.

## 3. Setup

### pubspec.yaml

    dependencies:
      camera: ^0.12.0+1
      hand_landmarker: ^3.0.1
      tflite_flutter: ^0.11.0

    flutter:
      assets:
        - assets/nsl.tflite
        - assets/meta.json
        - assets/parity.json

Requires Flutter SDK 3.44+ and JDK 17+. Verify with `flutter doctor`.
Note `hand_landmarker` depends on `camera ^0.12.0+1` — if the existing app
pins an older camera version, that must be resolved.

### android/app/build.gradle

    android {
        defaultConfig { minSdkVersion 24 }
        aaptOptions { noCompress 'tflite' }   // REQUIRED — R8 corrupts the model otherwise
    }

### AndroidManifest.xml

    <uses-permission android:name="android.permission.CAMERA"/>

## 4. Reference: the Python function that must be matched

This ran during training. The Dart port must be behaviourally identical.

    TIPS  = [4, 8, 12, 16, 20]
    CURLS = [(1,2,3), (5,6,7), (9,10,11), (13,14,15), (17,18,19)]

    def feats(lm):                        # lm: (21,3) float32
        lm = lm.astype(np.float32).copy()
        lm -= lm[0]                       # translate wrist to origin
        s = np.linalg.norm(lm[9] - lm[0]) # scale by wrist->middle-MCP distance
        if s < 1e-6: return None
        lm /= s

        out = [lm.reshape(-1)]                                    # 63 values

        for i in range(5):                                        # 10 values
            for j in range(i+1, 5):
                out.append([np.linalg.norm(lm[TIPS[i]] - lm[TIPS[j]])])

        for a, b, c in CURLS:                                     # 5 values
            v1, v2 = lm[b]-lm[a], lm[c]-lm[b]
            cs = v1 @ v2 / (np.linalg.norm(v1)*np.linalg.norm(v2) + 1e-8)
            out.append([np.arccos(np.clip(cs, -1, 1))])

        return np.concatenate(out)                                # 78 total

Exact output ordering (indices):

| Range | Content |
|---|---|
| 0–62 | 21 landmarks × (x, y, z), in landmark index order |
| 63–72 | Fingertip pair distances, loop order i=0..4, j=i+1..4 |
| 73–77 | Curl angles, in the CURLS list order |

Note: `mirror_left` is false. Do NOT apply any handedness flip.

## 5. Core classes to create

### lib/nsl/features.dart

    import 'dart:math' as math;
    import 'dart:typed_data';

    class Features {
      static const int dim = 78;
      static const _tips = [4, 8, 12, 16, 20];
      static const _curls = [[1,2,3],[5,6,7],[9,10,11],[13,14,15],[17,18,19]];

      /// 21 landmarks as [x,y,z] -> 78 raw features.
      /// Returns null for a degenerate hand (zero scale).
      static Float32List? compute(List<List<double>> raw) {
        if (raw.length != 21) return null;
        final lm = [for (final p in raw) List<double>.from(p)];

        final w = List<double>.from(lm[0]);
        for (final p in lm) { p[0]-=w[0]; p[1]-=w[1]; p[2]-=w[2]; }

        final s = math.sqrt(lm[9][0]*lm[9][0] + lm[9][1]*lm[9][1] + lm[9][2]*lm[9][2]);
        if (s < 1e-6) return null;
        for (final p in lm) { p[0]/=s; p[1]/=s; p[2]/=s; }

        final out = Float32List(dim);
        var k = 0;
        for (final p in lm) { out[k++]=p[0]; out[k++]=p[1]; out[k++]=p[2]; }

        for (var i = 0; i < 5; i++) {
          for (var j = i+1; j < 5; j++) {
            final a = lm[_tips[i]], b = lm[_tips[j]];
            final dx=a[0]-b[0], dy=a[1]-b[1], dz=a[2]-b[2];
            out[k++] = math.sqrt(dx*dx + dy*dy + dz*dz);
          }
        }
        for (final c in _curls) {
          final a=lm[c[0]], b=lm[c[1]], d=lm[c[2]];
          final v1=[b[0]-a[0], b[1]-a[1], b[2]-a[2]];
          final v2=[d[0]-b[0], d[1]-b[1], d[2]-b[2]];
          final dot = v1[0]*v2[0]+v1[1]*v2[1]+v1[2]*v2[2];
          final n1 = math.sqrt(v1[0]*v1[0]+v1[1]*v1[1]+v1[2]*v1[2]);
          final n2 = math.sqrt(v2[0]*v2[0]+v2[1]*v2[1]+v2[2]*v2[2]);
          out[k++] = math.acos((dot/(n1*n2 + 1e-8)).clamp(-1.0, 1.0));
        }
        return out;
      }

      static Float32List standardise(Float32List f, List<double> mu, List<double> sd) {
        final o = Float32List(f.length);
        for (var i = 0; i < f.length; i++) o[i] = (f[i]-mu[i])/sd[i];
        return o;
      }
    }

### lib/nsl/model.dart

    import 'dart:convert';
    import 'dart:math' as math;
    import 'dart:typed_data';
    import 'package:flutter/services.dart';
    import 'package:tflite_flutter/tflite_flutter.dart';

    class NslModel {
      late final Interpreter _it;
      late final List<String> labels;
      late final List<double> mu, sd;
      late final double confThreshold, detConf;
      late final int stableFrames;

      Future<void> load() async {
        _it = await Interpreter.fromAsset('assets/nsl.tflite');
        final m = jsonDecode(await rootBundle.loadString('assets/meta.json'));
        labels = List<String>.from(m['labels']);
        mu = (m['mu'] as List).map((e) => (e as num).toDouble()).toList();
        sd = (m['sd'] as List).map((e) => (e as num).toDouble()).toList();
        confThreshold = (m['conf_threshold'] as num).toDouble();
        detConf       = (m['det_conf'] as num).toDouble();
        stableFrames  = (m['stable_frames'] as num).toInt();

        assert(labels.length == 36);
        assert(mu.length == 78 && sd.length == 78);
      }

      /// Input must be standardised. Returns LOGITS.
      List<double> infer(Float32List std) {
        final out = List.generate(1, (_) => List.filled(labels.length, 0.0));
        _it.run([std], out);
        return List<double>.from(out[0]);
      }

      static List<double> softmax(List<double> z) {
        final mx = z.reduce(math.max);
        final e = z.map((v) => math.exp(v - mx)).toList();
        final s = e.reduce((a,b) => a+b);
        return e.map((v) => v/s).toList();
      }

      void dispose() => _it.close();
    }

Note on `tflite_flutter`: `run()` expects a pre-allocated nested output list
matching shape `[1, 36]`. A flat list will fail or produce garbage.

## 6. PARITY TEST — HARD GATE

Implement and run this BEFORE any camera or UI work.

### lib/nsl/parity.dart

    import 'dart:convert';
    import 'dart:typed_data';
    import 'package:flutter/services.dart';
    import 'features.dart';
    import 'model.dart';

    class ParityResult {
      final double featDiff, logitDiff;
      final int agree, total;
      ParityResult(this.featDiff, this.logitDiff, this.agree, this.total);
      bool get pass => featDiff < 1e-3 && logitDiff < 1e-2 && agree == total;
      @override String toString() =>
        'featDiff=${featDiff.toStringAsExponential(2)} '
        'logitDiff=${logitDiff.toStringAsExponential(2)} '
        'agree=$agree/$total ${pass ? "PASS" : "FAIL"}';
    }

    Future<ParityResult> runParity(NslModel model) async {
      final p = jsonDecode(await rootBundle.loadString('assets/parity.json'));
      final lms = p['landmarks'] as List;
      final feats = p['feats'] as List;
      final logits = p['logits'] as List;

      double fd = 0, ld = 0;
      int agree = 0;

      for (var i = 0; i < lms.length; i++) {
        // Stage 1 — tests Features.compute()
        final raw = (lms[i] as List).map<List<double>>(
            (r) => (r as List).map((e) => (e as num).toDouble()).toList()).toList();
        final got = Features.compute(raw);
        if (got == null) throw StateError('compute() returned null at $i');
        final exp = (feats[i] as List).map((e) => (e as num).toDouble()).toList();
        for (var j = 0; j < got.length; j++) {
          final d = (got[j]-exp[j]).abs();
          if (d > fd) fd = d;
        }

        // Stage 2 — tests the interpreter + standardisation
        final gl = model.infer(Features.standardise(got, model.mu, model.sd));
        final el = (logits[i] as List).map((e) => (e as num).toDouble()).toList();
        for (var j = 0; j < gl.length; j++) {
          final d = (gl[j]-el[j]).abs();
          if (d > ld) ld = d;
        }
        if (_argmax(gl) == _argmax(el)) agree++;
      }
      return ParityResult(fd, ld, agree, lms.length);
    }

    int _argmax(List<double> v) {
      var b = 0;
      for (var i = 1; i < v.length; i++) if (v[i] > v[b]) b = i;
      return b;
    }

### Pass criteria

| Metric | Threshold |
|---|---|
| featDiff | < 1e-3 |
| logitDiff | < 1e-2 |
| agree | 30/30 (must be exact) |

Small non-zero diffs are expected — Dart computes in 64-bit double,
NumPy used 32-bit float. Argmax agreement is what matters.

### Debugging a failure

| Symptom | Likely cause |
|---|---|
| featDiff large | Ordering bug in `compute()`. Check the `i<j` loop and CURLS order. Print indices 60-78 of both arrays and compare |
| featDiff ok, logitDiff large | mu/sd not applied, applied twice, or wrong output tensor shape |
| Everything ok but agree < 30 | Should not happen — recheck `_argmax` |
| Model fails to load | Missing `noCompress 'tflite'` in build.gradle |

Also write this as a Flutter integration test so it runs in CI.

## 7. Live pipeline

Only after parity passes.

### Plugin API (hand_landmarker 3.0.1)

The plugin is **stream-based**, not call-and-return:

    _plugin = HandLandmarkerPlugin.create(
      numHands: 1,
      minHandDetectionConfidence: 0.30,   // MUST be 0.30 — matches training extraction
      delegate: HandLandmarkerDelegate.gpu,
    );

    await _controller.startImageStream((image) {
      _plugin.processFrame(image, _controller.description.sensorOrientation);
    });

    _plugin.landmarkStream.listen((List<Hand> hands) { ... });

`Hand.landmarks` is a `List<Landmark>`, each with `.x`, `.y`, `.z` doubles.
Convert to `List<List<double>>` for `Features.compute()`.

Call `_plugin.dispose()` and `_controller.dispose()` in widget dispose.

### lib/nsl/recognizer.dart

    class Recognizer {
      final NslModel model;
      Recognizer(this.model);

      int _stable = 0, _lastIdx = -1;
      DateTime _cooldownUntil = DateTime.fromMillisecondsSinceEpoch(0);
      final List<String> emitted = [];

      // exposed for the debug overlay
      String? topLabel;
      double topConf = 0;
      int stableCount = 0;

      void onHands(List<Hand> hands) {
        if (DateTime.now().isBefore(_cooldownUntil)) return;
        if (hands.isEmpty) { _reset(); return; }

        final raw = hands.first.landmarks
            .map((l) => [l.x, l.y, l.z]).toList();
        final f = Features.compute(raw);
        if (f == null) { _reset(); return; }

        final p = NslModel.softmax(
            model.infer(Features.standardise(f, model.mu, model.sd)));
        var best = 0;
        for (var i = 1; i < p.length; i++) if (p[i] > p[best]) best = i;

        topLabel = model.labels[best];
        topConf = p[best];

        // Confidence gate comes BEFORE the stability counter.
        // Reversed, low-confidence predictions smooth into a stable
        // wrong answer, which looks confident and is worse than flicker.
        if (p[best] < model.confThreshold) { _reset(); return; }

        if (best == _lastIdx) {
          _stable++;
          if (_stable >= model.stableFrames) {
            emitted.add(model.labels[best]);
            _cooldownUntil = DateTime.now().add(const Duration(milliseconds: 500));
            _reset();
          }
        } else {
          _lastIdx = best;
          _stable = 1;
        }
        stableCount = _stable;
      }

      void _reset() { _stable = 0; _lastIdx = -1; stableCount = 0; }
      void clear() { emitted.clear(); _reset(); }
      void backspace() { if (emitted.isNotEmpty) emitted.removeLast(); }
    }

### Threading

`infer()` is synchronous and runs on the UI isolate. The model is tiny
(~200 KB, 50k params) so this should be sub-millisecond. Measure it.
If frame drops appear, throttle to every Nth landmark event before
considering an isolate — the plugin already does detection off-thread.

## 8. Debug UI

Add a debug screen (hidden behind a long-press or dev flag) showing:

- Parity result string, run on app start
- Live: top-1 label, confidence, stability counter, hand-detected boolean
- Sliders for `confThreshold` (0.5–0.95) and `stableFrames` (3–15)
- Cooldown ms field
- Emitted character string, with clear and backspace

These sliders are needed for on-device tuning. The model has no
"no sign" class, so it always predicts something when a hand is visible.
The confidence gate is the only defence against junk output during
transitions between characters — expect to raise it above 0.70.

## 9. Known limitations

- **No NONE class.** Any visible hand produces a prediction. Confidence
  gating is the only mitigation.
- **Weak classes.** ठ (F1 0.69) and ट (F1 0.77) are frequently confused
  with each other; ञ/ख also swap. These are landmark-ambiguous poses.
  Do not attempt to fix in app code.
- **Android only.** The plugin has no iOS support.
- **MediaPipe version drift.** Training used Python mediapipe 0.10.14.
  The plugin bundles its own `.task` model of unknown version. If parity
  passes but live accuracy is visibly poor, this is the prime suspect —
  report it rather than tuning around it, since the fix is to re-extract
  and retrain, not to change app code.

## 10. Definition of done

1. `flutter analyze` clean
2. Parity test passes: 30/30 agreement
3. Parity runs as an integration test
4. Live camera produces characters for clearly-formed signs at arm's length
5. Debug overlay shows label, confidence, stability
6. Thresholds adjustable at runtime
7. No frame drops in the preview