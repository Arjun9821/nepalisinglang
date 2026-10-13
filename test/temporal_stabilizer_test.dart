import 'package:flutter_test/flutter_test.dart';
import 'package:nsl_fyp/nsl/stabilized_event.dart';
import 'package:nsl_fyp/nsl/temporal_stabilizer.dart';

/// Covers the stabilizer half of the spec's section 11 checklist.
///
/// Every test drives an explicit clock rather than real time, so the
/// millisecond thresholds are asserted exactly instead of approximately.
void main() {
  const frameMs = 150;

  TemporalStabilizer build() => TemporalStabilizer(
        confidenceThreshold: 0.80,
        stableFrameCount: 3,
        idleGapMs: 500,
        wordBoundaryMs: 1200,
        sentencePauseMs: 2000,
      );

  /// Feeds [count] identical frames starting at [startMs] and returns every
  /// event produced, along with the timestamp one frame past the last.
  (List<StabilizedEvent>, int) feed(
    TemporalStabilizer s,
    String char,
    int count, {
    int startMs = 0,
    double confidence = 0.95,
    bool handDetected = true,
  }) {
    final events = <StabilizedEvent>[];
    var now = startMs;
    for (var i = 0; i < count; i++) {
      events.addAll(s.ingest(
        char: char,
        confidence: confidence,
        handDetected: handDetected,
        nowMs: now,
      ));
      now += frameMs;
    }
    return (events, now);
  }

  group('character confirmation', () {
    test('confirms after exactly stableFrameCount frames', () {
      final s = build();
      final (events, _) = feed(s, 'क', 3);
      expect(events, hasLength(1));
      expect(events.single.type, StabilizedEventType.charConfirmed);
      expect(events.single.char, 'क');
      expect(events.single.confidence, 0.95);
    });

    test('holding one letter steadily emits exactly one event', () {
      // 3s of continuous holding at ~6.6fps.
      final s = build();
      final (events, _) = feed(s, 'क', 20);
      expect(
        events.where((e) => e.type == StabilizedEventType.charConfirmed),
        hasLength(1),
      );
    });

    test('noisy transition frames shorter than K produce nothing', () {
      final s = build();
      final events = <StabilizedEvent>[];
      var now = 0;
      // Two frames each of four different classes — a hand moving between
      // signs, never settling.
      for (final char in ['क', 'ख', 'ट', 'ठ']) {
        for (var i = 0; i < 2; i++) {
          events.addAll(
            s.ingest(char: char, confidence: 0.99, nowMs: now),
          );
          now += frameMs;
        }
      }
      expect(events, isEmpty);
    });

    test('frames below the confidence threshold never count', () {
      final s = build();
      final (events, _) = feed(s, 'क', 10, confidence: 0.79);
      expect(events, isEmpty);
    });

    test('a confident label with no hand detected never counts', () {
      // The classifier always returns an argmax, so a hand-less frame can look
      // extremely confident. It must not become a letter.
      final s = build();
      final (events, _) = feed(s, 'क', 10, confidence: 0.99, handDetected: false);
      expect(events, isEmpty);
    });

    test('a changed class restarts the count', () {
      final s = build();
      var (events, now) = feed(s, 'क', 2);
      expect(events, isEmpty);
      // One frame of something else resets progress...
      events = s.ingest(char: 'ख', confidence: 0.95, nowMs: now);
      now += frameMs;
      expect(events, isEmpty);
      // ...so two more frames of the original are still not enough.
      final (more, _) = feed(s, 'क', 2, startMs: now);
      expect(more, isEmpty);
    });

    test('a different letter after a confirmation confirms in turn', () {
      final s = build();
      final (first, now) = feed(s, 'क', 3);
      expect(first, hasLength(1));
      final (second, _) = feed(s, 'ख', 3, startMs: now);
      expect(second, hasLength(1));
      expect(second.single.char, 'ख');
    });
  });

  group('boundaries', () {
    test('a pause past wordBoundaryMs emits one wordBoundary', () {
      final s = build();
      final (_, now) = feed(s, 'क', 3);
      final lastActive = now - frameMs;

      expect(s.tick(lastActive + 600), isEmpty, reason: 'idle but under 1200ms');

      final atBoundary = s.tick(lastActive + 1200);
      expect(atBoundary, hasLength(1));
      expect(atBoundary.single.type, StabilizedEventType.wordBoundary);

      // Latched: continued idling below the sentence threshold stays silent.
      expect(s.tick(lastActive + 1500), isEmpty);
    });

    test('a pause past sentencePauseMs emits one sentencePause', () {
      final s = build();
      final (_, now) = feed(s, 'क', 3);
      final lastActive = now - frameMs;

      s.tick(lastActive + 1200);
      final atPause = s.tick(lastActive + 2000);
      expect(atPause, hasLength(1));
      expect(atPause.single.type, StabilizedEventType.sentencePause);

      // Nothing more, however long the camera stares at an empty room -- the
      // case the spec's skeleton got wrong in the other direction.
      expect(s.tick(lastActive + 5000), isEmpty);
      expect(s.tick(lastActive + 60000), isEmpty);
    });

    test('a single sparse tick can emit both boundaries in order', () {
      final s = build();
      final (_, now) = feed(s, 'क', 3);
      final events = s.tick(now - frameMs + 3000);
      expect(
        events.map((e) => e.type),
        [StabilizedEventType.wordBoundary, StabilizedEventType.sentencePause],
      );
    });

    test('no boundary events before anything has been signed', () {
      final s = build();
      expect(s.tick(100000), isEmpty);
    });

    test('boundaries re-arm once the user signs again', () {
      final s = build();
      final (_, now) = feed(s, 'क', 3);
      var t = now - frameMs;
      expect(s.tick(t + 2000), hasLength(2));

      final (second, afterSecond) = feed(s, 'ख', 3, startMs: t + 3000);
      expect(second, hasLength(1));
      t = afterSecond - frameMs;
      expect(s.tick(t + 2000), hasLength(2));
    });

    test('the same letter repeats only when separated by a real pause', () {
      final s = build();
      final (first, now) = feed(s, 'क', 3);
      expect(first, hasLength(1));

      // Brief dip below threshold — shorter than idleGapMs, so this is still
      // one continuous hold and must not double the letter.
      var t = now;
      s.ingest(char: 'क', confidence: 0.2, nowMs: t);
      t += frameMs;
      final (again, afterAgain) = feed(s, 'क', 5, startMs: t);
      expect(again, isEmpty);

      // A full idle gap resets the hold, so the next one is a genuine repeat.
      t = afterAgain - frameMs;
      s.tick(t + 600);
      final (repeat, _) = feed(s, 'क', 3, startMs: t + 700);
      expect(repeat, hasLength(1));
      expect(repeat.single.char, 'क');
    });
  });

  group('candidateProgress', () {
    test('tracks progress towards confirmation and clears when idle', () {
      final s = build();
      expect(s.candidateProgress, 0);
      feed(s, 'क', 1);
      expect(s.candidateProgress, closeTo(1 / 3, 1e-9));
      feed(s, 'क', 1, startMs: frameMs);
      expect(s.candidateProgress, closeTo(2 / 3, 1e-9));
      s.tick(10000);
      expect(s.candidateChar, isNull);
      expect(s.candidateProgress, 0);
    });
  });

  test('reset clears everything', () {
    final s = build();
    feed(s, 'क', 3);
    s.reset();
    expect(s.state, StabilizerState.idle);
    expect(s.candidateChar, isNull);
    expect(s.tick(100000), isEmpty);
  });
}
