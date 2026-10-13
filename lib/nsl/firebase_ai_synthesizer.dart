import 'package:firebase_ai/firebase_ai.dart';
import 'package:flutter/foundation.dart';

import '../core/config/app_config.dart';
import 'sentence_synthesizer.dart';

/// Calls Gemini through Firebase AI Logic (section 5 of the spec).
///
/// Preferred over [GeminiRestSentenceSynthesizer] because no API key lands on
/// the device: Firebase proxies the request and authenticates the caller via App
/// Check with the Play Integrity provider, on the no-cost Gemini Developer tier.
///
/// Enabling it: run `flutterfire configure`; pick the **Gemini Developer API**
/// backend under Build -> AI Logic in the Firebase console; uncomment the
/// bootstrap block in `main()` (it needs the generated
/// `lib/firebase_options.dart`); set [AppConfig.useFirebaseAiSynthesizer] true;
/// and for debug builds register the App Check debug token printed to logcat --
/// without it every call fails attestation, which surfaces here only as a null
/// return and a "couldn't refine" hint.
///
/// Until the bootstrap block is live, constructing this throws, because
/// `FirebaseAI.googleAI()` needs an initialised default Firebase app. The
/// provider catches that and falls back.
class FirebaseAiSentenceSynthesizer extends PromptingSentenceSynthesizer {
  final GenerativeModel _model;
  final String modelName;
  final Duration timeout;

  FirebaseAiSentenceSynthesizer({
    String model = AppConfig.sentenceModel,
    this.timeout = AppConfig.llmTimeout,
  })  : modelName = model,
        _model = FirebaseAI.googleAI().generativeModel(
          model: model,
          generationConfig: GenerationConfig(
            temperature: AppConfig.llmTemperature,
            maxOutputTokens: AppConfig.llmMaxOutputTokens,
          ),
        );

  @override
  String get backendLabel => 'Firebase AI Logic ($modelName)';

  @override
  Future<String?> synthesize(String raw) async {
    if (raw.trim().isEmpty) return null;
    try {
      final response = await _model
          .generateContent([Content.text(buildPrompt(raw))]).timeout(timeout);

      // A truncated reply looks like a finished sentence and would be spoken as
      // one -- see GeminiRestSentenceSynthesizer.
      final finishReason = response.candidates.isEmpty
          ? null
          : response.candidates.first.finishReason;
      if (finishReason == FinishReason.maxTokens) {
        debugPrint('[NSL] Firebase AI hit the output token limit; discarding.');
        return null;
      }

      final sentence =
          PromptingSentenceSynthesizer.cleanResponse(response.text);
      if (sentence == null || sentence.isEmpty) return null;
      rememberSentence(sentence);
      return sentence;
    } catch (e) {
      // Timeout, no network, App Check rejection, safety block -- the caller
      // only needs "no sentence this time".
      debugPrint('[NSL] Firebase AI synthesize failed: $e');
      return null;
    }
  }
}
