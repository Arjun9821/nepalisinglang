import 'package:equatable/equatable.dart';

import 'recognition_mode.dart';

/// A single recognition output, from the on-device model or the remote API.
///
/// TODO(AI-INTEGRATION): the shape both recognition services should return.
class RecognitionResult extends Equatable {
  final String recognizedText;
  final double confidence;
  final DateTime timestamp;
  final RecognitionMode mode;

  /// Whether a hand was actually localised in this frame.
  ///
  /// The classifier always returns *some* argmax label, so confidence alone is a
  /// poor "is the user signing?" signal, and [TemporalStabilizer] needs the
  /// distinction to detect word and sentence boundaries. Defaults to true for
  /// producers with no hand detector -- an unknown answer must not read as "no
  /// hand", or the pipeline treats every frame as idle.
  final bool handDetected;

  const RecognitionResult({
    required this.recognizedText,
    required this.confidence,
    required this.timestamp,
    required this.mode,
    this.handDetected = true,
  });

  /// A neutral placeholder result shown before any inference has run.
  factory RecognitionResult.empty(RecognitionMode mode) {
    return RecognitionResult(
      recognizedText: '',
      confidence: 0,
      timestamp: DateTime.now(),
      mode: mode,
      handDetected: false,
    );
  }

  RecognitionResult copyWith({
    String? recognizedText,
    double? confidence,
    DateTime? timestamp,
    RecognitionMode? mode,
    bool? handDetected,
  }) {
    return RecognitionResult(
      recognizedText: recognizedText ?? this.recognizedText,
      confidence: confidence ?? this.confidence,
      timestamp: timestamp ?? this.timestamp,
      mode: mode ?? this.mode,
      handDetected: handDetected ?? this.handDetected,
    );
  }

  @override
  List<Object?> get props =>
      [recognizedText, confidence, timestamp, mode, handDetected];
}