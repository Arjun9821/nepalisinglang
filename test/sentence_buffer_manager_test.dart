import 'package:flutter_test/flutter_test.dart';
import 'package:nsl_fyp/nsl/buffer_manager.dart';
import 'package:nsl_fyp/nsl/stabilized_event.dart';

/// Covers each flush trigger from the spec's section 4 independently, plus
/// the "buffer flush never sends an empty string" checklist item.
void main() {
  late List<String> flushes;
  late List<String> bufferUpdates;

  SentenceBufferManager build({int maxBufferChars = 30}) {
    return SentenceBufferManager(
      maxBufferChars: maxBufferChars,
      onFlush: flushes.add,
      onBufferChanged: bufferUpdates.add,
    );
  }

  StabilizedEvent char(String c) => StabilizedEvent(
        type: StabilizedEventType.charConfirmed,
        char: c,
        confidence: 0.9,
        timestampMs: 0,
      );

  const wordBoundary =
      StabilizedEvent(type: StabilizedEventType.wordBoundary, timestampMs: 0);
  const sentencePause =
      StabilizedEvent(type: StabilizedEventType.sentencePause, timestampMs: 0);

  setUp(() {
    flushes = [];
    bufferUpdates = [];
  });

  group('accumulation', () {
    test('confirmed characters append and are reported immediately', () {
      final b = build();
      b.handleEvents([char('न'), char('म')]);
      expect(b.rawText, 'नम');
      expect(bufferUpdates, ['न', 'नम']);
      expect(flushes, isEmpty);
    });

    test('a word boundary inserts one separator', () {
      final b = build();
      b.handleEvents([char('न'), wordBoundary, char('म')]);
      expect(b.rawText, 'न|म');
    });

    test('repeated word boundaries do not stack separators', () {
      final b = build();
      b.handleEvents([char('न'), wordBoundary, wordBoundary, wordBoundary]);
      expect(b.rawText, 'न|');
    });

    test('a leading word boundary is dropped', () {
      final b = build();
      b.handleEvents([wordBoundary, char('न')]);
      expect(b.rawText, 'न');
    });
  });

  group('flush triggers', () {
    test('sentencePause flushes and empties the buffer', () {
      final b = build();
      b.handleEvents([char('न'), char('म'), sentencePause]);
      expect(flushes, ['नम']);
      expect(b.isEmpty, isTrue);
    });

    test('reaching maxBufferChars flushes without a pause', () {
      final b = build(maxBufferChars: 3);
      b.handleEvents([char('क'), char('ख'), char('ग')]);
      expect(flushes, ['कखग']);
      expect(b.isEmpty, isTrue);
    });

    test('flushManually flushes whatever is buffered', () {
      final b = build();
      b.handleEvents([char('क')]);
      b.flushManually();
      expect(flushes, ['क']);
    });
  });

  group('empty and separator-only flushes', () {
    test('an empty buffer never reaches the synthesizer', () {
      final b = build();
      b.flushManually();
      b.onStabilizedEvent(sentencePause);
      expect(flushes, isEmpty);
    });

    test('a separator-only buffer never reaches the synthesizer', () {
      // Happens when a word boundary lands right after a previous flush.
      final b = build();
      b.handleEvents([char('क'), sentencePause]);
      expect(flushes, ['क']);

      b.handleEvents([char('ख')]);
      b.removeLast();
      b.handleEvents([wordBoundary, sentencePause]);
      expect(flushes, ['क'], reason: 'no second flush for an empty buffer');
    });

    test('trailing separators are stripped before flushing', () {
      final b = build();
      b.handleEvents([char('न'), char('म'), wordBoundary, sentencePause]);
      expect(flushes, ['नम']);
    });
  });

  group('editing', () {
    test('removeLast drops the last letter and any separator behind it', () {
      final b = build();
      b.handleEvents([char('न'), wordBoundary, char('म')]);
      expect(b.rawText, 'न|म');
      b.removeLast();
      expect(b.rawText, 'न');
    });

    test('removeLast on an empty buffer is a no-op', () {
      final b = build();
      b.removeLast();
      expect(b.isEmpty, isTrue);
      expect(bufferUpdates, isEmpty);
    });

    test('clear empties without synthesizing', () {
      final b = build();
      b.handleEvents([char('न')]);
      b.clear();
      expect(b.isEmpty, isTrue);
      expect(flushes, isEmpty);
    });
  });
}
