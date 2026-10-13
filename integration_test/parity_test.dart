import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nsl_fyp/nsl/model.dart';
import 'package:nsl_fyp/nsl/parity.dart';

/// The section 6 HARD GATE, on a real device -- the TFLite interpreter needs
/// native libraries the pure-Dart test VM does not load. This must pass before
/// the live camera pipeline is trusted.
///
///   flutter test integration_test/parity_test.dart -d <device-id>
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late NslModel model;

  setUpAll(() async {
    model = NslModel();
    await model.load();
  });

  tearDownAll(() => model.dispose());

  testWidgets('model metadata matches the bundled interpreter', (_) async {
    expect(model.labels.length, 36);
    expect(model.mu.length, 78);
    expect(model.sd.length, 78);
    // mirror_left is false for this model; a handedness flip must NOT be
    // applied anywhere in the pipeline.
    expect(model.mirrorLeft, isFalse);
  });

  testWidgets('parity gate: features + logits match training', (_) async {
    final result = await runParity(model);
    // Printed so the value is visible in CI logs even on success.
    // ignore: avoid_print
    print('[NSL] PARITY $result');

    expect(
      result.pass,
      isTrue,
      reason: 'Parity gate failed: $result\n'
          'featDiff large      -> ordering bug in Features.compute(); compare '
          'indices 63-77 against the Python.\n'
          'featDiff ok, logitDiff large -> mu/sd not applied, applied twice, '
          'or wrong output tensor shape.\n'
          'Model fails to load -> missing noCompress "tflite" in '
          'android/app/build.gradle.kts.',
    );
  });
}
