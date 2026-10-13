/// What [TemporalStabilizer] can tell the rest of the pipeline: a letter held
/// long enough to be real (once per hold), a pause implying a space, or a pause
/// implying the user is done, which triggers a flush to the sentence synthesizer.
enum StabilizedEventType { charConfirmed, wordBoundary, sentencePause }

/// A single discrete event distilled from the noisy per-frame prediction
/// stream. [char] and [confidence] are only populated for [charConfirmed].
class StabilizedEvent {
  final StabilizedEventType type;
  final String? char;
  final double? confidence;
  final int timestampMs;

  const StabilizedEvent({
    required this.type,
    this.char,
    this.confidence,
    required this.timestampMs,
  });

  @override
  String toString() => type == StabilizedEventType.charConfirmed
      ? 'StabilizedEvent(charConfirmed, "$char", '
          '${confidence?.toStringAsFixed(2)}, t=$timestampMs)'
      : 'StabilizedEvent(${type.name}, t=$timestampMs)';
}
