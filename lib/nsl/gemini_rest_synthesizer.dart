import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/config/app_config.dart';
import 'sentence_synthesizer.dart';

/// Calls the Gemini Developer API directly over HTTPS, with the key supplied at
/// build time via `--dart-define=GEMINI_API_KEY=...`.
///
/// The backend that works today, with no Firebase project or console setup. The
/// trade-off: a `--dart-define` keeps the key out of version control, not out of
/// the binary, so it is recoverable from the APK. Acceptable for a free-tier
/// project key, and why [AppConfig.useFirebaseAiSynthesizer] is the intended end
/// state -- Firebase AI Logic puts no key on the device at all.
class GeminiRestSentenceSynthesizer extends PromptingSentenceSynthesizer {
  final String apiKey;
  final String model;
  final Duration timeout;
  final http.Client _client;

  GeminiRestSentenceSynthesizer({
    required this.apiKey,
    this.model = AppConfig.sentenceModel,
    this.timeout = AppConfig.llmTimeout,
    http.Client? client,
  }) : _client = client ?? http.Client();

  @override
  String get backendLabel => 'Gemini ($model)';

  @override
  Future<String?> synthesize(String raw) async {
    if (apiKey.isEmpty || raw.trim().isEmpty) return null;

    final uri = Uri.https(
      'generativelanguage.googleapis.com',
      '/v1beta/models/$model:generateContent',
    );

    try {
      final response = await _client
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              // Header rather than a query parameter, so the key does not end
              // up in proxy or server request logs.
              'x-goog-api-key': apiKey,
            },
            body: jsonEncode({
              'contents': [
                {
                  'role': 'user',
                  'parts': [
                    {'text': buildPrompt(raw)},
                  ],
                },
              ],
              'generationConfig': {
                'temperature': AppConfig.llmTemperature,
                'maxOutputTokens': AppConfig.llmMaxOutputTokens,
              },
            }),
          )
          .timeout(timeout);

      if (response.statusCode != 200) {
        debugPrint(
          '[NSL] Gemini HTTP ${response.statusCode}: ${response.body}',
        );
        return null;
      }

      // Decode explicitly as UTF-8: `response.body` falls back to latin-1 when
      // the server omits a charset, which mangles Devanagari.
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));

      // A truncated reply is worse than none: it comes back as a
      // grammatical-looking fragment that would be displayed and spoken as a
      // finished sentence. Fall back to the raw letters instead.
      final finishReason = _finishReason(decoded);
      if (finishReason == 'MAX_TOKENS') {
        debugPrint(
          '[NSL] Gemini hit the output token limit; discarding the truncated '
          'sentence. Raise AppConfig.llmMaxOutputTokens if this recurs.',
        );
        return null;
      }

      final sentence = PromptingSentenceSynthesizer.cleanResponse(
        _extractText(decoded),
      );
      if (sentence == null || sentence.isEmpty) return null;

      rememberSentence(sentence);
      return sentence;
    } catch (e) {
      // Timeout, no network, malformed payload — all the same to the caller,
      // which falls back to the raw letter stream.
      debugPrint('[NSL] Gemini synthesize failed: $e');
      return null;
    }
  }

  /// `candidates[0].finishReason`, or null if the response has no candidates.
  static String? _finishReason(dynamic decoded) {
    if (decoded is! Map) return null;
    final candidates = decoded['candidates'];
    if (candidates is! List || candidates.isEmpty) return null;
    final reason = (candidates.first as Map?)?['finishReason'];
    return reason is String ? reason : null;
  }

  /// Pulls the text out of `candidates[0].content.parts[*].text`, tolerating
  /// a response that was blocked or truncated into a shape without it.
  static String? _extractText(dynamic decoded) {
    if (decoded is! Map) return null;
    final candidates = decoded['candidates'];
    if (candidates is! List || candidates.isEmpty) return null;
    final content = (candidates.first as Map?)?['content'];
    if (content is! Map) return null;
    final parts = content['parts'];
    if (parts is! List) return null;
    final buffer = StringBuffer();
    for (final part in parts) {
      final text = (part as Map?)?['text'];
      if (text is String) buffer.write(text);
    }
    final text = buffer.toString();
    return text.isEmpty ? null : text;
  }

  @override
  void dispose() => _client.close();
}
