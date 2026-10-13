import '../core/config/app_config.dart';
import 'buffer_manager.dart';

/// Turns a raw stream of recognised letters into a sentence.
///
/// Implementations must never throw and never block longer than
/// [AppConfig.llmTimeout] -- the sentence layer is an enhancement, and the app
/// stays useful showing raw letters. Null means the stream was not refined.
abstract class SentenceSynthesizer {
  /// Which backend this is, shown in the UI so it is obvious during a demo
  /// whether the LLM path is live.
  String get backendLabel;

  /// Whether this backend does real correction, rather than just joining.
  bool get isRefining;

  /// [raw] is the buffered stream, e.g. `न|म|स|त|े`, with
  /// [SentenceBufferManager.wordSeparator] marking likely word boundaries.
  Future<String?> synthesize(String raw);

  /// Drops conversation context, e.g. when the user clears the screen.
  void resetSession();

  void dispose() {}
}

/// Shared prompt construction and rolling conversation history for the backends
/// that call a language model. Both send the identical prompt, so a difference in
/// output is a difference in the model or transport.
abstract class PromptingSentenceSynthesizer implements SentenceSynthesizer {
  final List<String> _history = [];

  /// How many previous sentences are carried as context.
  int get historyLimit => AppConfig.sentenceHistoryLength;

  List<String> get history => List.unmodifiable(_history);

  @override
  bool get isRefining => true;

  @override
  void resetSession() => _history.clear();

  @override
  void dispose() {}

  /// Records a successful sentence, evicting the oldest past [historyLimit].
  void rememberSentence(String sentence) {
    _history.add(sentence);
    while (_history.length > historyLimit) {
      _history.removeAt(0);
    }
  }

  String buildPrompt(String raw) {
    final context = _history.isEmpty
        ? ''
        : 'Previous sentences in this conversation:\n${_history.join('\n')}\n\n';
    return '$systemPrompt\n\n$examples\n\n${context}Input: $raw\nOutput:';
  }

  static const String systemPrompt = '''
You are correcting a noisy stream of Nepali (Devanagari) letters produced by
a sign-language fingerspelling recognizer. The letters may contain
misrecognitions of visually similar hand shapes. Your job:

1. Segment the letter stream into words (a '|' marks a likely word boundary,
   but boundaries can be wrong — use judgement).
2. Fix likely misrecognized letters based on context, choosing the most
   probable real Nepali word.
3. Produce one fluent, grammatical Nepali sentence.
4. Use ONLY the information in the letter stream — do not invent unrelated
   content. If the stream is too short or unclear, return your best-effort
   phrase rather than refusing.

Respond with the corrected sentence only. No explanation, no quotes.''';

  static const String examples = '''
Input: न|म|स|त|े
Output: नमस्ते।

Input: म|क|ा|ठ|म|ा|ड|ौ|ं|ज|ा|न|छ|ु
Output: म काठमाडौं जान्छु।''';

  /// Strips the decorations a model sometimes adds despite being told not to.
  static String? cleanResponse(String? text) {
    if (text == null) return null;
    var cleaned = text.trim();
    if (cleaned.startsWith('Output:')) {
      cleaned = cleaned.substring('Output:'.length).trim();
    }
    // Surrounding quotes of either flavour.
    if (cleaned.length >= 2) {
      final first = cleaned[0];
      final last = cleaned[cleaned.length - 1];
      const quotes = {'"', "'", '“', '”', '‘', '’'};
      if (quotes.contains(first) && quotes.contains(last)) {
        cleaned = cleaned.substring(1, cleaned.length - 1).trim();
      }
    }
    // A multi-line reply ignored "sentence only"; keep the first non-empty line
    // rather than speaking an explanation aloud.
    final firstLine = cleaned
        .split('\n')
        .map((line) => line.trim())
        .firstWhere((line) => line.isNotEmpty, orElse: () => '');
    return firstLine.isEmpty ? null : firstLine;
  }
}

/// The always-available backend: joins the recognised letters mechanically,
/// turning word separators into spaces. It corrects nothing, but keeps the
/// sentence panel, history and text-to-speech working with no network, no API
/// key and no Firebase project.
class LocalJoinSentenceSynthesizer implements SentenceSynthesizer {
  @override
  String get backendLabel => 'On-device (no correction)';

  @override
  bool get isRefining => false;

  @override
  Future<String?> synthesize(String raw) async {
    final words = raw
        .split(SentenceBufferManager.wordSeparator)
        .map((w) => w.trim())
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return null;
    return '${words.join(' ')}।';
  }

  @override
  void resetSession() {}

  @override
  void dispose() {}
}
