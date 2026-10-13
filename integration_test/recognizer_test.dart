import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hand_landmarker/hand_landmarker.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nsl_fyp/nsl/model.dart';
import 'package:nsl_fyp/nsl/recognizer.dart';

/// Behavioural tests for [Recognizer], on a real device -- it runs the TFLite
/// interpreter, which needs native libraries the pure-Dart test VM does not
/// load.
///
/// The contract under test is the one that matters downstream: a frame with no
/// usable hand and a frame with a weak-but-real prediction must stay
/// distinguishable, because `TemporalStabilizer` treats them differently.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late NslModel model;
  late List<dynamic> landmarks;
  late List<dynamic> logits;

  Hand handFrom(List<dynamic> row) => Hand([
        for (final p in row)
          Landmark(
            (p[0] as num).toDouble(),
            (p[1] as num).toDouble(),
            (p[2] as num).toDouble(),
          ),
      ]);

  int argmax(List<dynamic> v) {
    var b = 0;
    for (var i = 1; i < v.length; i++) {
      if ((v[i] as num) > (v[b] as num)) b = i;
    }
    return b;
  }

  setUpAll(() async {
    model = NslModel();
    await model.load();
    final p = jsonDecode(await rootBundle.loadString('assets/parity.json'))
        as Map<String, dynamic>;
    landmarks = p['landmarks'] as List;
    logits = p['logits'] as List;
  });

  tearDownAll(() => model.dispose());

  testWidgets('no hand -> empty result, handDetected false, reason noHand',
      (_) async {
    final r = Recognizer(model);
    final out = r.recognize(const []);

    expect(out.handDetected, isFalse);
    expect(out.recognizedText, isEmpty);
    expect(out.confidence, 0);
    expect(r.lastSkipReason, SkipReason.noHand);
    expect(r.topLabel, isNull);
  });

  testWidgets('degenerate hand -> empty result, reason degenerateHand',
      (_) async {
    final r = Recognizer(model);
    // Every landmark coincident with the wrist: wrist->middle-MCP distance is
    // 0, so the features cannot be scale-normalised.
    final degenerate = Hand([for (var i = 0; i < 21; i++) Landmark(1, 2, 3)]);
    final out = r.recognize([degenerate]);

    expect(out.handDetected, isFalse);
    expect(out.recognizedText, isEmpty);
    expect(r.lastSkipReason, SkipReason.degenerateHand);
  });

  testWidgets('real landmarks -> label matching the model, handDetected true',
      (_) async {
    final r = Recognizer(model);
    var matched = 0;

    for (var i = 0; i < landmarks.length; i++) {
      final out = r.recognize([handFrom(landmarks[i] as List)]);

      expect(out.handDetected, isTrue, reason: 'row $i');
      expect(out.recognizedText, isNotEmpty, reason: 'row $i');
      expect(out.confidence, greaterThan(0), reason: 'row $i');
      expect(out.confidence, lessThanOrEqualTo(1), reason: 'row $i');
      expect(r.lastSkipReason, SkipReason.none, reason: 'row $i');

      // Compare against what the model predicts (argmax of the stored logits),
      // not the ground-truth label: it is ~92% accurate, so asserting against
      // `true` would fail on its genuine misclassifications.
      if (out.recognizedText == model.labels[argmax(logits[i] as List)]) {
        matched++;
      }
    }

    expect(matched, landmarks.length,
        reason: 'Recognizer disagreed with the model on '
            '${landmarks.length - matched} of ${landmarks.length} rows -- the '
            'softmax/argmax path or the label lookup is wrong.');
  });

  testWidgets('low confidence is returned, never collapsed to empty', (_) async {
    final r = Recognizer(model);
    // Whatever the confidence, the result must carry a real label with
    // handDetected true, so TemporalStabilizer decides whether it counts.
    final out = r.recognize([handFrom(landmarks.first as List)]);

    expect(out.handDetected, isTrue);
    expect(out.recognizedText, isNotEmpty);
    expect(out.confidence, greaterThan(0));
  });

  testWidgets('detection rate tracks a rolling window, not since launch',
      (_) async {
    final r = Recognizer(model, detectionWindow: 4);
    expect(r.detectionSamples, 0);

    // Four misses -> 0%.
    for (var i = 0; i < 4; i++) {
      r.recognize(const []);
    }
    expect(r.detectionSamples, 4);
    expect(r.detectionRate, 0);

    // Four hits evict all four misses -> 100%, proving it is windowed rather
    // than cumulative.
    for (var i = 0; i < 4; i++) {
      r.recognize([handFrom(landmarks.first as List)]);
    }
    expect(r.detectionSamples, 4);
    expect(r.detectionRate, 1.0);

    // Two misses -> 50%.
    r.recognize(const []);
    r.recognize(const []);
    expect(r.detectionRate, closeTo(0.5, 1e-9));
  });

  testWidgets('a degenerate hand still counts as detected', (_) async {
    final r = Recognizer(model, detectionWindow: 4);
    final degenerate = Hand([for (var i = 0; i < 21; i++) Landmark(1, 2, 3)]);
    r.recognize([degenerate]);

    // MediaPipe found a hand the classifier could not use. Detection rate
    // answers "is MediaPipe seeing the hand", so this counts as a hit; the
    // unusability is reported through lastSkipReason.
    expect(r.detectionRate, 1.0);
    expect(r.lastSkipReason, SkipReason.degenerateHand);
  });

  testWidgets('reset clears the overlay figures', (_) async {
    final r = Recognizer(model);
    r.recognize([handFrom(landmarks.first as List)]);
    expect(r.topLabel, isNotNull);

    r.reset();
    expect(r.topLabel, isNull);
    expect(r.topConf, 0);
    expect(r.lastSkipReason, SkipReason.none);
    expect(r.detectionSamples, 0);
    expect(r.detectionRate, 0);
  });
}
