import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config/app_config.dart';
import '../data/models/recognition_result.dart';
import '../services/history/sentence_history_store.dart';
import '../services/tts/tts_service.dart';
import 'buffer_manager.dart';
import 'sentence_synthesizer.dart';
import 'stabilized_event.dart';
import 'temporal_stabilizer.dart';

/// What the sentence panel is currently showing.
enum SentenceStatus {
  idle,
  buffering,
  synthesizing,
  ready,

  /// A sentence is on screen but no language model shaped it -- the call failed
  /// or no LLM backend is configured. Only the correction step is missing.
  unrefined,
}

@immutable
class SentencePipelineState {
  /// The debounced letter stream, `|` marking word boundaries. Updated the
  /// instant a letter is confirmed, never waiting on the network.
  final String letters;

  /// Most recent synthesized sentence, empty before the first flush.
  final String sentence;

  final SentenceStatus status;

  /// Previously synthesized sentences, newest last.
  final List<String> history;

  final bool autoSpeak;
  final bool isSpeaking;

  /// Note about degraded operation, null when everything worked.
  final String? notice;

  const SentencePipelineState({
    this.letters = '',
    this.sentence = '',
    this.status = SentenceStatus.idle,
    this.history = const [],
    this.autoSpeak = AppConfig.autoSpeakSentence,
    this.isSpeaking = false,
    this.notice,
  });

  bool get hasSentence => sentence.isNotEmpty;

  SentencePipelineState copyWith({
    String? letters,
    String? sentence,
    SentenceStatus? status,
    List<String>? history,
    bool? autoSpeak,
    bool? isSpeaking,
    String? notice,
    bool clearNotice = false,
  }) {
    return SentencePipelineState(
      letters: letters ?? this.letters,
      sentence: sentence ?? this.sentence,
      status: status ?? this.status,
      history: history ?? this.history,
      autoSpeak: autoSpeak ?? this.autoSpeak,
      isSpeaking: isSpeaking ?? this.isSpeaking,
      notice: clearNotice ? null : (notice ?? this.notice),
    );
  }
}

/// Owns the whole letters-to-speech path: stabilizer, buffer, synthesizer and
/// text-to-speech. The screen only feeds it [ingest] and button presses.
class SentencePipelineController extends StateNotifier<SentencePipelineState> {
  final TemporalStabilizer _stabilizer;
  late final SentenceBufferManager _buffer;
  final SentenceSynthesizer _synthesizer;
  final TTSService _tts;

  /// Durable record of what was said. Optional so tests skip platform storage.
  final SentenceHistoryStore? _historyStore;

  /// Used when [_synthesizer] returns nothing.
  final SentenceSynthesizer _fallback;

  Timer? _idleTicker;

  /// The letters most recently sent for synthesis, displayed while the buffer is
  /// empty so that flushing does not blank the panel the user is reading.
  String _lastFlushedRaw = '';

  /// Invalidates in-flight synthesis when a newer flush, or a clear, happens
  /// first, so a slow response cannot overwrite a newer sentence.
  int _flushGeneration = 0;

  SentencePipelineController({
    required SentenceSynthesizer synthesizer,
    required TTSService tts,
    TemporalStabilizer? stabilizer,
    SentenceSynthesizer? fallback,
    SentenceHistoryStore? historyStore,
  })  : _synthesizer = synthesizer,
        _tts = tts,
        _historyStore = historyStore,
        _fallback = fallback ?? LocalJoinSentenceSynthesizer(),
        _stabilizer = stabilizer ??
            TemporalStabilizer(
              confidenceThreshold: AppConfig.sentenceConfidenceThreshold,
              stableFrameCount: AppConfig.stableFrameCount,
              idleGapMs: AppConfig.idleGapMs,
              wordBoundaryMs: AppConfig.wordBoundaryMs,
              sentencePauseMs: AppConfig.sentencePauseMs,
            ),
        super(const SentencePipelineState()) {
    _buffer = SentenceBufferManager(
      maxBufferChars: AppConfig.maxBufferChars,
      onFlush: _onFlush,
      onBufferChanged: _onBufferChanged,
    );
  }

  /// Which backend is in use, for the UI to display.
  String get backendLabel => _synthesizer.backendLabel;

  /// Whether that backend actually corrects the letter stream.
  bool get backendRefines => _synthesizer.isRefining;

  /// How close the current sign is to confirmation, in `[0, 1]`. Read directly
  /// rather than through state, since it changes on every frame.
  double get holdProgress => _stabilizer.candidateProgress;

  String? get candidateChar => _stabilizer.candidateChar;

  bool get hasBufferedLetters => !_buffer.isEmpty;

  /// Starts the wall-clock idle ticker; call when the screen takes the camera.
  void start() {
    _idleTicker ??= Timer.periodic(
      AppConfig.sentenceIdleTickInterval,
      (_) => _handleEvents(_stabilizer.tick(_nowMs())),
    );
  }

  /// Stops the ticker and flushes whatever is buffered — a screen losing the
  /// camera is the spec's "app goes to background" flush trigger.
  void stop() {
    _idleTicker?.cancel();
    _idleTicker = null;
    _stabilizer.reset();
    if (mounted && !_buffer.isEmpty) _buffer.flushManually();
  }

  /// Feeds one classifier result into the pipeline.
  void ingest(RecognitionResult result) {
    _handleEvents(
      _stabilizer.ingest(
        char: result.recognizedText,
        confidence: result.confidence,
        handDetected: result.handDetected,
        nowMs: _nowMs(),
      ),
    );
  }

  /// The "Done" button: synthesize whatever is buffered right now.
  void flushNow() => _buffer.flushManually();

  /// Deletes the most recently confirmed letter.
  void undoLastLetter() => _buffer.removeLast();

  /// Wipes letters, sentence and conversation history.
  void clearAll() {
    _flushGeneration++;
    _buffer.clear();
    _stabilizer.reset();
    _synthesizer.resetSession();
    _fallback.resetSession();
    _lastFlushedRaw = '';
    unawaited(_tts.stop());
    // Auto-speak survives: it is the user's setting, not part of the utterance.
    state = SentencePipelineState(autoSpeak: state.autoSpeak);
  }

  /// Live-tunes the stabilizer's gating from the debug screen. Routed through
  /// the controller so a caller cannot reset the stabilizer out from under an
  /// in-progress hold; existing progress is preserved.
  void setTuning({double? confidenceThreshold, int? stableFrameCount}) {
    if (confidenceThreshold != null) {
      _stabilizer.confidenceThreshold = confidenceThreshold;
    }
    if (stableFrameCount != null && stableFrameCount >= 1) {
      _stabilizer.stableFrameCount = stableFrameCount;
    }
  }

  /// Current gating values, so the debug sliders can show what is in force.
  double get confidenceThreshold => _stabilizer.confidenceThreshold;
  int get stableFrameCount => _stabilizer.stableFrameCount;

  void toggleAutoSpeak() => state = state.copyWith(autoSpeak: !state.autoSpeak);

  /// Speaks the current sentence, or stops if already speaking.
  Future<void> speakOrStop() async {
    if (state.isSpeaking) {
      await _tts.stop();
      if (mounted) state = state.copyWith(isSpeaking: false);
      return;
    }
    if (!state.hasSentence) return;
    await _speak(state.sentence);
  }

  void _onBufferChanged(String rawBuffer) {
    if (!mounted) return;
    final display = rawBuffer.isNotEmpty ? rawBuffer : _lastFlushedRaw;
    state = state.copyWith(
      letters: display,
      // Only claim "buffering" while something is accumulating: an empty buffer
      // after a flush must not overwrite the synthesizing state.
      status:
          rawBuffer.isNotEmpty && state.status != SentenceStatus.synthesizing
              ? SentenceStatus.buffering
              : state.status,
    );
  }

  Future<void> _onFlush(String raw) async {
    if (!mounted) return;
    final generation = ++_flushGeneration;
    _lastFlushedRaw = raw;
    state = state.copyWith(
      letters: raw,
      status: SentenceStatus.synthesizing,
      clearNotice: true,
    );

    var sentence = await _synthesizer.synthesize(raw);
    var refined = sentence != null && _synthesizer.isRefining;
    String? notice;

    if (sentence == null) {
      // Graceful degradation: the letters are already on screen, so join them.
      sentence = await _fallback.synthesize(raw);
      notice = _synthesizer.isRefining
          ? "Couldn't reach the language model — showing the raw letters."
          : null;
    }
    if (!_synthesizer.isRefining) {
      // The key is a compile-time constant, so the build lacked it.
      notice = 'No API key compiled in — letters are joined as-is, not '
          'corrected. Relaunch with --dart-define-from-file=env.json.';
    }

    // A newer flush (or a clear) happened while this was in flight.
    if (!mounted || generation != _flushGeneration) return;

    if (sentence == null || sentence.isEmpty) {
      state = state.copyWith(status: SentenceStatus.idle, clearNotice: true);
      return;
    }

    final history = [...state.history, sentence];
    while (history.length > AppConfig.sentenceHistoryLength) {
      history.removeAt(0);
    }

    state = state.copyWith(
      sentence: sentence,
      status: refined ? SentenceStatus.ready : SentenceStatus.unrefined,
      history: history,
      notice: notice,
      clearNotice: notice == null,
    );

    // Fire-and-forget: a storage failure must never delay the utterance.
    unawaited(_historyStore?.add(sentence) ?? Future<void>.value());

    if (state.autoSpeak) {
      unawaited(_speak(sentence));
    }
  }

  Future<void> _speak(String text) async {
    await _tts.initialize();
    if (!_tts.hasDevanagariVoice) {
      if (mounted) {
        state = state.copyWith(
          isSpeaking: false,
          notice: 'No Nepali or Hindi voice is installed. In Android Settings, '
              'open Accessibility > Text-to-speech output and install a '
              'Nepali or Hindi voice.',
        );
      }
      return;
    }
    state = state.copyWith(isSpeaking: true);
    await _tts.speak(text);
    // awaitSpeakCompletion(true) means this resolves when playback finishes.
    if (mounted) state = state.copyWith(isSpeaking: false);
  }

  void _handleEvents(List<StabilizedEvent> events) {
    if (events.isEmpty) return;
    for (final event in events) {
      if (kDebugMode) debugPrint('[NSL] $event');
      _buffer.onStabilizedEvent(event);
    }
  }

  int _nowMs() => DateTime.now().millisecondsSinceEpoch;

  @override
  void dispose() {
    _idleTicker?.cancel();
    _synthesizer.dispose();
    _fallback.dispose();
    super.dispose();
  }
}
