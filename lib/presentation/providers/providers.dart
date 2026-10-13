import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/app_config.dart';
import '../../data/models/recognition_mode.dart';
import '../../data/models/recognition_result.dart';
import '../../data/repositories/offline_recognition_repository_impl.dart';
import '../../domain/repositeries/recognition_repository.dart';
import '../../nsl/firebase_ai_synthesizer.dart';
import '../../nsl/gemini_rest_synthesizer.dart';
import '../../data/models/recognition_backend.dart';
import '../../nsl/model.dart';
import '../../nsl/parity.dart';
import '../../nsl/recognizer.dart';
import '../../nsl/sentence_pipeline_controller.dart';
import '../../nsl/sentence_synthesizer.dart';
import '../../services/camera/camera_service.dart';
import '../../services/history/sentence_history_store.dart';
import '../../services/tts/tts_service.dart';

// --- Cross-cutting services (shared by both modes) ---

/// A fresh [CameraService] per screen -- offline/online each own their camera
/// lifecycle.
final cameraServiceProvider = Provider.autoDispose<CameraService>((ref) {
  final service = CameraService();
  ref.onDispose(service.dispose);
  return service;
});

/// TTS is stateless enough to share a single instance app-wide.
final ttsServiceProvider = Provider<TTSService>((ref) => TTSService());

// --- Recognition repositories ---

final offlineRecognitionRepositoryProvider =
    Provider.autoDispose<RecognitionRepository>((ref) {
  final repo = OfflineRecognitionRepository();
  ref.onDispose(repo.dispose);
  return repo;
});

// --- Bottom navigation selected index (Learn=0, Home=1, Live=2, History=3) ---

final bottomNavIndexProvider = StateProvider<int>((ref) => 1);

// --- Sentence pipeline ---

/// Every raw per-frame prediction, ungated: the live readout, which keeps
/// updating while the stabilizer discards those same frames.
final offlineLiveResultProvider = StateProvider.autoDispose<RecognitionResult>(
  (ref) => RecognitionResult.empty(RecognitionMode.offline),
);

/// Picks the sentence backend, most capable first: Firebase AI Logic -> Gemini
/// REST (key via `--dart-define`) -> local join. Degrades instead of failing;
/// see [AppConfig] for how to enable each.
final sentenceSynthesizerProvider = Provider<SentenceSynthesizer>((ref) {
  if (AppConfig.useFirebaseAiSynthesizer) {
    try {
      return FirebaseAiSentenceSynthesizer();
    } catch (e) {
      // A half-finished Firebase setup should cost refinement, not the app.
      debugPrint('[NSL] Firebase AI unavailable, falling back: $e');
    }
  }
  if (AppConfig.geminiApiKey.isNotEmpty) {
    debugPrint(
      '[NSL] Sentence backend: Gemini REST (${AppConfig.sentenceModel}), '
      'key length ${AppConfig.geminiApiKey.length}.',
    );
    return GeminiRestSentenceSynthesizer(apiKey: AppConfig.geminiApiKey);
  }
  // The key is a compile-time constant, so empty means the build lacked it.
  debugPrint(
    '[NSL] Sentence backend: on-device join. GEMINI_API_KEY was empty at '
    'COMPILE time. Relaunch (not hot reload) with '
    '--dart-define-from-file=env.json to enable correction.',
  );
  return LocalJoinSentenceSynthesizer();
});

/// Owns the stabilizer, buffer, synthesizer and TTS for the offline screen.
///
/// Not autoDispose, so the letters survive a tab switch. No `onDispose(stop)`
/// either: `stop()` flushes the buffer, which writes to `state` and throws once
/// disposed -- the screen calls it while everything is still alive.
final sentencePipelineProvider =
    StateNotifierProvider<SentencePipelineController, SentencePipelineState>(
        (ref) {
  return SentencePipelineController(
    synthesizer: ref.watch(sentenceSynthesizerProvider),
    tts: ref.watch(ttsServiceProvider),
    historyStore: ref.watch(sentenceHistoryStoreProvider),
  );
});

// --- Landmark recognition path (spec sections 7-8) ---

/// Loads `assets/nsl.tflite` + `meta.json` once for the app's lifetime. Not
/// autoDispose: cheap to hold (~200 KB), expensive to rebuild.
final nslModelProvider = FutureProvider<NslModel>((ref) async {
  final model = NslModel();
  await model.load();
  ref.onDispose(model.dispose);
  return model;
});

/// The landmark recogniser, null until [nslModelProvider] resolves. Shared, so
/// the Live tab and the debug overlay report the same figures.
final recognizerProvider = Provider<Recognizer?>((ref) {
  final model = ref.watch(nslModelProvider).valueOrNull;
  return model == null ? null : Recognizer(model);
});

/// Which on-device classifier the Live tab runs. Switchable from the debug
/// screen so the two can be compared on the same hand, back to back.
final recognitionBackendProvider =
    StateProvider<RecognitionBackend>((ref) => RecognitionBackend.landmark);

/// Explains when Live has switched to the image backend because MediaPipe
/// could not initialize on this device.
final recognitionBackendNoticeProvider = StateProvider<String?>((ref) => null);

/// Raw per-frame result for the Live tab readout, as [offlineLiveResultProvider].
final liveResultProvider = StateProvider.autoDispose<RecognitionResult>(
  (ref) => RecognitionResult.empty(RecognitionMode.offline),
);

/// The section 6 parity gate, run lazily and cached: ~2s of inference for a
/// number only read on the debug screen. The integration test is what protects
/// the build.
final parityResultProvider = FutureProvider<ParityResult>((ref) async {
  final model = await ref.watch(nslModelProvider.future);
  return runParity(model);
});

/// Bumped when the active lens changes, so the Live screen re-resolves the
/// recogniser's mirroring rule.
final lensGenerationProvider = StateProvider<int>((ref) => 0);

// --- Sentence history (durable, user-facing) ---

final sentenceHistoryStoreProvider =
    Provider<SentenceHistoryStore>((ref) => SentenceHistoryStore());

/// Saved sentences, newest last. Invalidate to reload after a write.
final sentenceHistoryProvider = FutureProvider<List<HistoryEntry>>(
  (ref) => ref.watch(sentenceHistoryStoreProvider).load(),
);
