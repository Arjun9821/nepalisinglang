import 'package:equatable/equatable.dart';

import 'recognition_result.dart';

/// A rolling log of past recognition results. Not persisted yet -- intended to
/// back a future history panel.
class PredictionHistory extends Equatable {
  final List<RecognitionResult> entries;

  const PredictionHistory({this.entries = const []});

  PredictionHistory addEntry(RecognitionResult result) {
    return PredictionHistory(entries: [...entries, result]);
  }

  PredictionHistory clear() => const PredictionHistory(entries: []);

  @override
  List<Object?> get props => [entries];
}