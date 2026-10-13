import 'package:flutter_test/flutter_test.dart';
import 'package:nsl_fyp/data/models/recognition_mode.dart';
import 'package:nsl_fyp/data/models/recognition_result.dart';
import 'package:nsl_fyp/nsl/sentence_pipeline_controller.dart';
import 'package:nsl_fyp/nsl/sentence_synthesizer.dart';
import 'package:nsl_fyp/nsl/temporal_stabilizer.dart';
import 'package:nsl_fyp/services/tts/tts_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('confirmed Nepali letter becomes displayed text and is spoken',
      () async {
    final tts = _RecordingTts();
    final controller = SentencePipelineController(
      synthesizer: LocalJoinSentenceSynthesizer(),
      tts: tts,
      stabilizer: TemporalStabilizer(
        confidenceThreshold: 0.5,
        stableFrameCount: 2,
        idleGapMs: 10,
        wordBoundaryMs: 20,
        sentencePauseMs: 30,
      ),
    );
    addTearDown(controller.dispose);

    final result = RecognitionResult(
      recognizedText: 'म',
      confidence: 0.99,
      timestamp: DateTime.now(),
      mode: RecognitionMode.offline,
      handDetected: true,
    );
    final nextResult = RecognitionResult(
      recognizedText: 'घ',
      confidence: 0.99,
      timestamp: DateTime.now(),
      mode: RecognitionMode.offline,
      handDetected: true,
    );
    controller
      ..ingest(result)
      ..ingest(result)
      ..ingest(nextResult)
      ..ingest(nextResult);

    expect(controller.state.letters, 'मघ');
    controller.flushNow();
    await Future<void>.delayed(Duration.zero);

    expect(controller.state.sentence, 'मघ।');
    expect(tts.spoken, ['मघ।']);
  });
}

class _RecordingTts extends TTSService {
  final List<String> spoken = [];

  @override
  Future<void> speak(String text) async => spoken.add(text);

  @override
  Future<void> stop() async {}
}
