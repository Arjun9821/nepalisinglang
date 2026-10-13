import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nsl_fyp/nsl/gemini_rest_synthesizer.dart';
import 'package:nsl_fyp/nsl/sentence_synthesizer.dart';

/// Checks the "never throws, returns null instead" contract the whole
/// graceful-degradation story rests on (spec section 11), without touching
/// the network.
void main() {
  http.Response geminiOk(String text) => http.Response.bytes(
        utf8.encode(jsonEncode({
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': text},
                ],
              },
            },
          ],
        })),
        200,
        headers: {'content-type': 'application/json'},
      );

  GeminiRestSentenceSynthesizer withClient(http.Client client) =>
      GeminiRestSentenceSynthesizer(apiKey: 'test-key', client: client);

  group('LocalJoinSentenceSynthesizer', () {
    test('joins words on the separator and terminates the sentence', () async {
      final s = LocalJoinSentenceSynthesizer();
      expect(await s.synthesize('म|घर|जान्छु'), 'म घर जान्छु।');
    });

    test('returns null for an empty or separator-only stream', () async {
      final s = LocalJoinSentenceSynthesizer();
      expect(await s.synthesize(''), isNull);
      expect(await s.synthesize('||'), isNull);
    });

    test('reports that it does not refine', () {
      expect(LocalJoinSentenceSynthesizer().isRefining, isFalse);
    });
  });

  group('GeminiRestSentenceSynthesizer', () {
    test('returns the model sentence and remembers it as context', () async {
      final s = withClient(MockClient((_) async => geminiOk('नमस्ते।')));
      expect(await s.synthesize('न|म|स|त|े'), 'नमस्ते।');
      expect(s.history, ['नमस्ते।']);
    });

    test('decodes Devanagari as UTF-8 regardless of response charset', () async {
      // http defaults to latin-1 when the server omits a charset, which would
      // mangle the script if the body were read as a string.
      final s = withClient(MockClient((_) async => http.Response.bytes(
            utf8.encode(jsonEncode({
              'candidates': [
                {
                  'content': {
                    'parts': [
                      {'text': 'म काठमाडौं जान्छु।'},
                    ],
                  },
                },
              ],
            })),
            200,
          )));
      expect(await s.synthesize('म|क|ा'), 'म काठमाडौं जान्छु।');
    });

    test('sends the key as a header, never in the URL', () async {
      late http.Request captured;
      final s = withClient(MockClient((request) async {
        captured = request;
        return geminiOk('नमस्ते।');
      }));
      await s.synthesize('न|म');
      expect(captured.headers['x-goog-api-key'], 'test-key');
      expect(captured.url.query, isEmpty);
    });

    test('includes rolling history in the next prompt', () async {
      final prompts = <String>[];
      final s = withClient(MockClient((request) async {
        prompts.add(request.body);
        return geminiOk('नमस्ते।');
      }));
      await s.synthesize('न|म');
      await s.synthesize('क|ख');
      expect(prompts.last, contains('Previous sentences in this conversation'));
    });

    test('resetSession drops the history', () async {
      final s = withClient(MockClient((_) async => geminiOk('नमस्ते।')));
      await s.synthesize('न|म');
      s.resetSession();
      expect(s.history, isEmpty);
    });

    test('history is capped at the configured length', () async {
      var n = 0;
      final s = withClient(MockClient((_) async => geminiOk('वाक्य ${n++}।')));
      for (var i = 0; i < 8; i++) {
        await s.synthesize('क|ख');
      }
      expect(s.history, hasLength(s.historyLimit));
      expect(s.history.last, 'वाक्य 7।');
    });

    test('returns null on an HTTP error rather than throwing', () async {
      final s = withClient(
        MockClient((_) async => http.Response('quota exceeded', 429)),
      );
      expect(await s.synthesize('न|म'), isNull);
    });

    test('returns null when the transport fails', () async {
      final s = withClient(
        MockClient((_) async => throw const _NoNetwork()),
      );
      expect(await s.synthesize('न|म'), isNull);
    });

    test('discards a MAX_TOKENS reply rather than speaking a fragment',
        () async {
      // Observed for real: "म पानी खान" instead of "म पानी खान्छु।". It reads
      // as a finished sentence, so it has to be rejected on finishReason, not
      // on how the text looks.
      final s = withClient(MockClient((_) async => http.Response.bytes(
            utf8.encode(jsonEncode({
              'candidates': [
                {
                  'finishReason': 'MAX_TOKENS',
                  'content': {
                    'parts': [
                      {'text': 'म पानी खान'},
                    ],
                  },
                },
              ],
            })),
            200,
          )));
      expect(await s.synthesize('म|प|ा|न|ी'), isNull);
      expect(s.history, isEmpty);
    });

    test('returns null on a blocked response with no candidates', () async {
      final s = withClient(MockClient(
        (_) async => http.Response(jsonEncode({'promptFeedback': {}}), 200),
      ));
      expect(await s.synthesize('न|म'), isNull);
    });

    test('returns null without calling out when no key is configured', () async {
      var called = false;
      final s = GeminiRestSentenceSynthesizer(
        apiKey: '',
        client: MockClient((_) async {
          called = true;
          return geminiOk('नमस्ते।');
        }),
      );
      expect(await s.synthesize('न|म'), isNull);
      expect(called, isFalse);
    });

    test('times out instead of hanging the pipeline', () async {
      final s = GeminiRestSentenceSynthesizer(
        apiKey: 'test-key',
        timeout: const Duration(milliseconds: 50),
        client: MockClient((_) async {
          await Future<void>.delayed(const Duration(seconds: 2));
          return geminiOk('नमस्ते।');
        }),
      );
      expect(await s.synthesize('न|म'), isNull);
    });
  });

  group('cleanResponse', () {
    String? clean(String? s) => PromptingSentenceSynthesizer.cleanResponse(s);

    test('strips an echoed Output: prefix', () {
      expect(clean('Output: नमस्ते।'), 'नमस्ते।');
    });

    test('strips surrounding quotes of either flavour', () {
      expect(clean('"नमस्ते।"'), 'नमस्ते।');
      expect(clean('“नमस्ते।”'), 'नमस्ते।');
    });

    test('keeps only the first line when the model explains itself', () {
      expect(clean('नमस्ते।\n\nThis means hello.'), 'नमस्ते।');
    });

    test('maps null and whitespace to null', () {
      expect(clean(null), isNull);
      expect(clean('   \n  '), isNull);
    });
  });
}

class _NoNetwork implements Exception {
  const _NoNetwork();
}
