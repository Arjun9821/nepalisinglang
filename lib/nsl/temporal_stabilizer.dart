import 'stabilized_event.dart';

enum StabilizerState { idle, candidate, holding }

/// Collapses the noisy per-frame prediction stream into discrete "letter
/// confirmed" events, and turns gaps in it into word and sentence boundaries.
///
/// A letter is reported only once it has survived [stableFrameCount] consecutive
/// frames, and only once per hold. Unlike the spec skeleton (section 3), the
/// idle reset and the boundary thresholds are evaluated independently and each
/// boundary latches once per pause, so `sentencePause` actually fires and a
/// single call can return more than one event.
class TemporalStabilizer {
  /// Minimum confidence for a frame to count as active signing. Mutable so the
  /// debug screen can tune it on device; the default was set against the image
  /// classifier, whose softmax is shaped differently from the landmark model's.
  double confidenceThreshold;

  /// Consecutive agreeing frames required to confirm a letter. Mutable too;
  /// lowering it mid-hold can confirm the current candidate on the next frame.
  int stableFrameCount;

  /// Idle duration after which the candidate counter resets.
  final int idleGapMs;

  /// Idle duration that implies a word boundary.
  final int wordBoundaryMs;

  /// Idle duration that implies the end of an utterance.
  final int sentencePauseMs;

  StabilizerState _state = StabilizerState.idle;
  String? _candidateChar;
  int _candidateCount = 0;

  /// Most recent active frame. Zero suppresses boundary events at startup.
  int _lastActiveTs = 0;

  /// The char emitted for the current hold, so one hold yields one event.
  String? _lastEmittedChar;

  /// Whether a letter has been confirmed since the last [sentencePause];
  /// without it an idle camera would emit boundary events forever.
  bool _hasPendingContent = false;

  /// Per-pause latches, re-armed by the next active frame.
  bool _wordBoundaryEmitted = false;
  bool _sentencePauseEmitted = false;

  TemporalStabilizer({
    this.confidenceThreshold = 0.80,
    this.stableFrameCount = 3,
    this.idleGapMs = 500,
    this.wordBoundaryMs = 1200,
    this.sentencePauseMs = 2000,
  })  : assert(stableFrameCount >= 1),
        assert(idleGapMs <= wordBoundaryMs),
        assert(wordBoundaryMs <= sentencePauseMs);

  StabilizerState get state => _state;

  /// The character currently accumulating frames, if any.
  String? get candidateChar => _candidateChar;

  /// How far the current candidate is towards confirmation, in `[0, 1]`.
  double get candidateProgress => _candidateChar == null
      ? 0
      : (_candidateCount / stableFrameCount).clamp(0.0, 1.0);

  /// Feeds one classifier result in, usually returning nothing. Pass
  /// [handDetected] false when the detector found no hand -- the label for such
  /// a frame is meaningless however confident it looks.
  List<StabilizedEvent> ingest({
    String? char,
    double confidence = 0,
    bool handDetected = true,
    required int nowMs,
  }) {
    final active = char != null &&
        char.isNotEmpty &&
        handDetected &&
        confidence >= confidenceThreshold;

    return active
        ? _ingestActive(char, confidence, nowMs)
        : _ingestIdle(nowMs);
  }

  /// Advances the clock without a new frame, so a pause is still detected when
  /// the camera stream stalls.
  List<StabilizedEvent> tick(int nowMs) => _ingestIdle(nowMs);

  /// Clears all state, e.g. when the screen releases the camera.
  void reset() {
    _state = StabilizerState.idle;
    _candidateChar = null;
    _candidateCount = 0;
    _lastActiveTs = 0;
    _lastEmittedChar = null;
    _hasPendingContent = false;
    _wordBoundaryEmitted = false;
    _sentencePauseEmitted = false;
  }

  List<StabilizedEvent> _ingestActive(String char, double confidence, int nowMs) {
    _lastActiveTs = nowMs;
    // Signing again re-arms both boundaries for the *next* pause.
    _wordBoundaryEmitted = false;
    _sentencePauseEmitted = false;

    if (char != _candidateChar) {
      // Fresh candidate, or the sign changed mid-hold: count from scratch.
      _candidateChar = char;
      _candidateCount = 1;
      _state = StabilizerState.candidate;
      return const [];
    }

    _candidateCount++;
    if (_candidateCount < stableFrameCount) {
      _state = StabilizerState.candidate;
      return const [];
    }

    _state = StabilizerState.holding;
    if (_lastEmittedChar == char) {
      // Still the same hold; already reported.
      return const [];
    }
    _lastEmittedChar = char;
    _hasPendingContent = true;
    return [
      StabilizedEvent(
        type: StabilizedEventType.charConfirmed,
        char: char,
        confidence: confidence,
        timestampMs: nowMs,
      ),
    ];
  }

  List<StabilizedEvent> _ingestIdle(int nowMs) {
    // Nothing has been signed yet, so there is no gap to measure.
    if (_lastActiveTs == 0) return const [];

    final gap = nowMs - _lastActiveTs;

    if (gap >= idleGapMs && _state != StabilizerState.idle) {
      _state = StabilizerState.idle;
      _candidateChar = null;
      _candidateCount = 0;
      // Clearing this lets a doubled letter be signed, separated by a pause.
      _lastEmittedChar = null;
    }

    // Boundaries only mean something with buffered content to separate.
    if (!_hasPendingContent) return const [];

    final events = <StabilizedEvent>[];
    if (gap >= wordBoundaryMs && !_wordBoundaryEmitted) {
      _wordBoundaryEmitted = true;
      events.add(
        StabilizedEvent(
          type: StabilizedEventType.wordBoundary,
          timestampMs: nowMs,
        ),
      );
    }
    if (gap >= sentencePauseMs && !_sentencePauseEmitted) {
      _sentencePauseEmitted = true;
      // The utterance is over: further idling stays silent until the next sign.
      _hasPendingContent = false;
      events.add(
        StabilizedEvent(
          type: StabilizedEventType.sentencePause,
          timestampMs: nowMs,
        ),
      );
    }
    return events;
  }
}
