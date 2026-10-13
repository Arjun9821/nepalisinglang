/// Environment / integration configuration.
class AppConfig {
  AppConfig._();

  // --- Offline (TensorFlow Lite) ---

  /// Silhouette classifier. Input `[1, 96, 96, 1]` float32 in `[0, 1]` from
  /// `NslPreprocessor`; output `[1, 36]` softmax over `NslLabels.characters`.
  static const String tfliteModelAssetPath =
      'assets/models/nsl_single_fp16.tflite';

  /// MediaPipe palm detection (full-range, 192x192), run as a crop stage
  /// before classification.
  static const String palmDetectionModelAssetPath =
      'assets/models/palm_detection.tflite';

  /// Whether to localise the hand before the training-time preprocessing chain.
  ///
  /// The chain's threshold-derived crop only lands on the hand when the frame
  /// is already a framed hand, as in the dataset. On a live frame it covers the
  /// whole room, leaving the hand a few pixels wide after the 96x96 resize.
  /// Set false to run the chain over the raw full frame, as the guide describes.
  static const bool useHandCropStage = true;

  // --- Online (API) ---
  // TODO(AI-INTEGRATION): point these at the real inference server.
  static const String apiBaseUrl = 'https://api.example.com';
  static const String recognizeEndpoint = '/v1/recognize';
  static const Duration apiTimeout = Duration(seconds: 10);

  // --- Frame sampling ---

  /// Upper bound on the capture rate, not a guarantee — screens skip a sample
  /// while the previous one is still on the recognition isolate. Together with
  /// [stableFrameCount] this sets how long each sign must be held.
  static const Duration frameSampleInterval = Duration(milliseconds: 150);

  // --- Sentence pipeline ---

  /// Minimum confidence for a frame to count as active signing (image model).
  /// Tuned on device; adjustable at runtime from the debug screen.
  static const double sentenceConfidenceThreshold = 0.80;

  /// The same, for the landmark model. A separate constant because the two
  /// softmax distributions are differently shaped, so one value cannot serve
  /// both. `meta.json`'s untested `conf_threshold` is ignored in favour of it.
  static const double landmarkConfidenceThreshold = 0.80;

  /// Consecutive agreeing frames before a letter is confirmed. Hold time =
  /// this x [frameSampleInterval]; retune against measured on-device fps.
  static const int stableFrameCount = 3;

  /// No-hand / low-confidence duration before the stabilizer returns to idle.
  static const int idleGapMs = 500;

  /// Idle duration implying a word boundary (inserts a separator).
  static const int wordBoundaryMs = 1200;

  /// Idle duration implying the utterance is finished (flushes the buffer).
  static const int sentencePauseMs = 2000;

  /// How often idle time is re-evaluated on a wall clock, so a pause is
  /// detected even if the camera stream stalls.
  static const Duration sentenceIdleTickInterval = Duration(milliseconds: 250);

  /// Buffered characters that force a flush even without a pause.
  static const int maxBufferChars = 30;

  // --- Sentence synthesis (LLM) ---

  /// Not `gemini-2.5-flash` (404 for new API keys), and not a reasoning model:
  /// those spent 239-348 hidden thinking tokens and 3.5-6s per call for
  /// identical output, exceeding [llmTimeout] half the time. Avoid `*-latest`
  /// aliases, which re-point at a new model without a code change.
  static const String sentenceModel = 'gemini-3.5-flash-lite';

  /// Measured latency is ~1-2s wired, and a demo runs on mobile data. Timing
  /// out drops the sentence to the uncorrected fallback.
  static const Duration llmTimeout = Duration(seconds: 6);

  static const double llmTemperature = 0.2;

  /// Well above the ~8 tokens a sentence needs. On reasoning models the budget
  /// also has to cover hidden thinking tokens, so a tight limit truncates into
  /// something that still reads — and would be spoken — as a real sentence.
  static const int llmMaxOutputTokens = 256;

  /// Previous sentences kept as LLM context, cleared on `resetSession()`.
  static const int sentenceHistoryLength = 5;

  /// Initial value only — the UI exposes a runtime toggle.
  static const bool autoSpeakSentence = true;

  /// Selects the Firebase AI Logic synthesizer over the direct REST one. Off
  /// until `flutterfire configure`, the AI Logic backend and an App Check debug
  /// token are in place — see `FirebaseAiSentenceSynthesizer`.
  static const bool useFirebaseAiSynthesizer = false;

  /// Supplied at build time (`--dart-define=GEMINI_API_KEY=...`) so nothing
  /// lands in version control; it is still recoverable from a release APK.
  /// Empty with Firebase off means `LocalJoinSentenceSynthesizer`.
  static const String geminiApiKey = String.fromEnvironment('GEMINI_API_KEY');
}
