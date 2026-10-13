import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

/// Thin wrapper around `flutter_tts`.
///
/// Many Android builds ship no Nepali voice, so [initialize] probes
/// [preferredLanguages] in order and remembers which one took;
/// [hasDevanagariVoice] lets the UI say when speech will not work.
class TTSService {
  /// Nepali first; Hindi is the fallback because it is far more commonly
  /// installed and reads the same script.
  static const List<String> preferredLanguages = ['ne-NP', 'hi-IN'];

  final FlutterTts _flutterTts = FlutterTts();
  bool _isInitialized = false;
  String? _language;

  /// The language actually in use, or null if neither preference was
  /// available and the engine's default is in play.
  String? get activeLanguage => _language;

  /// Whether a voice that can read Devanagari was found.
  bool get hasDevanagariVoice => _language != null;

  Future<void> initialize() async {
    if (_isInitialized) return;

    for (final language in preferredLanguages) {
      try {
        final available = await _flutterTts.isLanguageAvailable(language);
        if (available == true) {
          await _flutterTts.setLanguage(language);
          _language = language;
          break;
        }
      } catch (e) {
        debugPrint('[NSL] TTS language probe failed for $language: $e');
      }
    }
    if (_language == null) {
      debugPrint(
        '[NSL] No Devanagari TTS voice installed (tried $preferredLanguages); '
        'falling back to the engine default.',
      );
    }

    // Keep the platform engine's defaults if an optional setting is unsupported.
    try {
      await _flutterTts.awaitSpeakCompletion(true);
      await _flutterTts.setSpeechRate(0.45);
      await _flutterTts.setPitch(1.0);
      await _flutterTts.setVolume(1.0);
    } catch (e) {
      debugPrint('[NSL] TTS configuration failed; using engine defaults: $e');
    }
    _isInitialized = true;
  }

  /// Speaks [text], interrupting anything already being spoken.
  Future<void> speak(String text) async {
    if (text.trim().isEmpty) return;
    try {
      if (!_isInitialized) await initialize();
      // A new sentence supersedes the previous one; otherwise the engine queues
      // them and the user hears stale output.
      await _flutterTts.stop();
      await _flutterTts.speak(text);
    } catch (e) {
      debugPrint('[NSL] TTS speak failed: $e');
    }
  }

  Future<void> stop() async {
    try {
      await _flutterTts.stop();
    } catch (e) {
      debugPrint('[NSL] TTS stop failed: $e');
    }
  }
}
