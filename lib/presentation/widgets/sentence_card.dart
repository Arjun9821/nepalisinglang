import 'package:flutter/material.dart';

import '../../nsl/buffer_manager.dart';
import '../../nsl/sentence_pipeline_controller.dart';

/// The two-region output panel from section 6 of the sentence spec: the
/// debounced letter stream on top, the synthesized sentence below.
///
/// Kept visually separate because they update on different clocks -- letters the
/// instant the stabilizer confirms one, the sentence only after a pause and a
/// network round trip.
class SentenceCard extends StatelessWidget {
  final SentencePipelineState state;

  /// Which backend produced the sentence, e.g. `Gemini (gemini-2.5-flash)`.
  final String backendLabel;
  final bool hasBufferedLetters;

  final VoidCallback onDone;
  final VoidCallback onClear;
  final VoidCallback onUndo;
  final VoidCallback onSpeak;

  const SentenceCard({
    super.key,
    required this.state,
    required this.backendLabel,
    required this.hasBufferedLetters,
    required this.onDone,
    required this.onClear,
    required this.onUndo,
    required this.onSpeak,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.translate_rounded,
                    color: theme.colorScheme.primary, size: 20),
                const SizedBox(width: 8),
                Text(
                  'Nepali text',
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                _StatusChip(status: state.status),
              ],
            ),
            const SizedBox(height: 14),
            _LetterStream(letters: state.letters),
            const SizedBox(height: 12),
            _SentenceBox(state: state),
            if (state.notice != null) ...[
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline_rounded,
                      size: 16, color: theme.colorScheme.tertiary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      state.notice!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.tertiary,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: hasBufferedLetters ? onDone : null,
                    icon: const Icon(Icons.check_rounded),
                    label: const Text('Finish input'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: state.hasSentence ? onSpeak : null,
                    icon: Icon(state.isSpeaking
                        ? Icons.stop_rounded
                        : Icons.volume_up_rounded),
                    label: Text(state.isSpeaking ? 'Stop' : 'Speak'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextButton.icon(
                    onPressed: hasBufferedLetters ? onUndo : null,
                    icon: const Icon(Icons.backspace_outlined, size: 18),
                    label: const Text('Undo character'),
                  ),
                ),
                Expanded(
                  child: TextButton.icon(
                    onPressed: state.letters.isEmpty && !state.hasSentence
                        ? null
                        : onClear,
                    icon: const Icon(Icons.clear_all_rounded, size: 18),
                    label: const Text('Clear text'),
                  ),
                ),
              ],
            ),
            if (state.history.length > 1) ...[
              const Divider(height: 28),
              Text(
                'Earlier',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              // Newest last in state.history, and the newest is already in the
              // sentence box above.
              ...state.history.reversed.skip(1).map(
                    (sentence) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(
                        sentence,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
            ],
            const SizedBox(height: 12),
            Text(
              backendLabel,
              style: theme.textTheme.bodySmall?.copyWith(
                color:
                    theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The debounced letter stream. Word separators are rendered as a visible dot
/// rather than the raw `|` the prompt uses, which reads better as text.
class _LetterStream extends StatelessWidget {
  final String letters;

  const _LetterStream({required this.letters});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isEmpty = letters.isEmpty;
    final display = isEmpty
        ? 'Sign a letter to begin…'
        : letters.replaceAll(SentenceBufferManager.wordSeparator, ' · ');

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
      decoration: BoxDecoration(
        color:
            theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Recognized letters',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            display,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: isEmpty
                  ? theme.colorScheme.onSurfaceVariant
                  : theme.colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}

class _SentenceBox extends StatelessWidget {
  final SentencePipelineState state;

  const _SentenceBox({required this.state});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final synthesizing = state.status == SentenceStatus.synthesizing;

    // Keep the output useful while letters are being collected and while an
    // optional language model is working. Removing the internal `|` markers
    // gives a readable Nepali stream without waiting for a sentence pause.
    final liveText = state.letters
        .replaceAll(SentenceBufferManager.wordSeparator, ' ')
        .trim();
    final String text;
    if (state.hasSentence &&
        state.status != SentenceStatus.buffering &&
        !synthesizing) {
      text = state.sentence;
    } else if (liveText.isNotEmpty) {
      text = liveText;
    } else {
      text = 'Pause when you finish a word or sentence.';
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 16),
      decoration: BoxDecoration(
        color: state.hasSentence || liveText.isNotEmpty
            ? theme.colorScheme.primary.withValues(alpha: 0.06)
            : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          if (synthesizing && liveText.isEmpty) ...[
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: state.hasSentence || liveText.isNotEmpty
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final SentenceStatus status;

  const _StatusChip({required this.status});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final (String text, Color color) = switch (status) {
      SentenceStatus.idle => ('Idle', theme.colorScheme.onSurfaceVariant),
      SentenceStatus.buffering => ('Collecting', theme.colorScheme.primary),
      SentenceStatus.synthesizing => ('Refining', theme.colorScheme.primary),
      SentenceStatus.ready => ('Ready', theme.colorScheme.primary),
      SentenceStatus.unrefined => ('Raw', theme.colorScheme.tertiary),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
