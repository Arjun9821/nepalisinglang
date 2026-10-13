import 'stabilized_event.dart';

/// Accumulates confirmed letters and decides *when* the sentence synthesizer
/// should be called.
///
/// The point is one LLM call per utterance rather than per letter. Triggers
/// (section 4 of the spec): a [StabilizedEventType.sentencePause], the buffer
/// reaching [maxBufferChars], or [flushManually] (the Done button, or the app
/// going to background).
class SentenceBufferManager {
  /// Marks a likely word boundary. The prompt treats it as a hint, not truth.
  static const String wordSeparator = '|';

  final int maxBufferChars;

  /// Called with the raw buffer contents, never empty or separator-only.
  final void Function(String rawBuffer) onFlush;

  /// Called whenever the buffer changes, so the raw-stream panel can update
  /// without waiting on the network.
  final void Function(String rawBuffer)? onBufferChanged;

  final List<String> _buffer = [];

  SentenceBufferManager({
    required this.onFlush,
    this.onBufferChanged,
    this.maxBufferChars = 30,
  });

  /// Current buffer as a display/prompt string, e.g. `न|म|स|त|े`.
  String get rawText => _buffer.join();

  bool get isEmpty => _buffer.isEmpty;

  List<String> get characters => List.unmodifiable(_buffer);

  void handleEvents(Iterable<StabilizedEvent> events) {
    for (final event in events) {
      onStabilizedEvent(event);
    }
  }

  void onStabilizedEvent(StabilizedEvent event) {
    switch (event.type) {
      case StabilizedEventType.charConfirmed:
        _buffer.add(event.char!);
        onBufferChanged?.call(rawText);
        if (_buffer.length >= maxBufferChars) _flush();
      case StabilizedEventType.wordBoundary:
        // Leading and doubled separators only confuse the prompt.
        if (_buffer.isNotEmpty && _buffer.last != wordSeparator) {
          _buffer.add(wordSeparator);
          onBufferChanged?.call(rawText);
        }
      case StabilizedEventType.sentencePause:
        _flush();
    }
  }

  /// Flush triggered by the user rather than by a pause.
  void flushManually() => _flush();

  /// Drops the buffer without synthesizing anything.
  void clear() {
    if (_buffer.isEmpty) return;
    _buffer.clear();
    onBufferChanged?.call(rawText);
  }

  /// Removes the last confirmed character and any separator it left behind.
  void removeLast() {
    if (_buffer.isEmpty) return;
    _buffer.removeLast();
    if (_buffer.isNotEmpty && _buffer.last == wordSeparator) {
      _buffer.removeLast();
    }
    onBufferChanged?.call(rawText);
  }

  void _flush() {
    // A word boundary landing right after a flush leaves a separator-only
    // buffer. Synthesizing "|" wastes a call and returns a hallucination.
    final raw = _stripSeparators(rawText);
    if (_buffer.isEmpty && raw.isEmpty) return;
    _buffer.clear();
    // Emptying the buffer is a change like any other; keeping the just-flushed
    // letters on screen is the UI's job.
    onBufferChanged?.call('');
    if (raw.isEmpty) return;
    onFlush(raw);
  }

  static String _stripSeparators(String raw) {
    var start = 0;
    var end = raw.length;
    while (start < end && raw[start] == wordSeparator) {
      start++;
    }
    while (end > start && raw[end - 1] == wordSeparator) {
      end--;
    }
    final trimmed = raw.substring(start, end);
    return trimmed.replaceAll(wordSeparator, '').isEmpty ? '' : trimmed;
  }
}
