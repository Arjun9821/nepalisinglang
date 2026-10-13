import 'package:flutter/material.dart';

/// Compact always-on readout of what the classifier sees *this frame*.
///
/// Separate from the sentence panel on purpose: the stabilizer discards most
/// frames, which is what makes the letter stream clean but also makes the app
/// look frozen while working correctly and hides the raw signal needed to judge
/// accuracy. The progress bar shows how close the current sign is to being
/// committed, turning "hold still" into feedback.
class LivePredictionStrip extends StatelessWidget {
  /// Raw argmax label for the latest frame.
  final String label;

  /// Romanized label used by the supplied reference chart.
  final String? chartName;

  /// Raw softmax confidence for [label], in `[0, 1]`.
  final double confidence;

  /// Whether the palm detector localised a hand in this frame.
  final bool handDetected;

  /// Confidence the frame must reach to count towards a letter.
  final double threshold;

  /// Progress of the current candidate towards confirmation, in `[0, 1]`.
  final double holdProgress;

  const LivePredictionStrip({
    super.key,
    required this.label,
    required this.chartName,
    required this.confidence,
    required this.handDetected,
    required this.threshold,
    required this.holdProgress,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasPrediction = label.isNotEmpty;
    final counts = hasPrediction && handDetected && confidence >= threshold;

    final Color accent;
    final String statusText;
    if (!hasPrediction) {
      accent = theme.colorScheme.onSurfaceVariant;
      statusText = 'Starting…';
    } else if (!handDetected) {
      accent = theme.colorScheme.onSurfaceVariant;
      statusText = 'No hand detected — move one hand into the frame';
    } else if (!counts) {
      accent = theme.colorScheme.tertiary;
      statusText = 'Low confidence — hold steady in good light';
    } else {
      accent = theme.colorScheme.primary;
      statusText = 'Holding…';
    }

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 52,
              height: 52,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    counts ? label : (handDetected && hasPrediction ? '?' : '—'),
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: accent,
                    ),
                  ),
                  if (counts && chartName != null)
                    Text(
                      chartName!,
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: accent,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Text(
                        'Live prediction',
                        style: theme.textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        hasPrediction
                            ? '${(confidence * 100).toStringAsFixed(1)}%'
                            : '--',
                        style: theme.textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: accent,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    statusText,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      // Falls back to the confidence bar when nothing is held.
                      value: counts ? holdProgress : confidence,
                      minHeight: 5,
                      backgroundColor: theme.colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.6),
                      valueColor: AlwaysStoppedAnimation(accent),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
