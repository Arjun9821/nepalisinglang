import 'dart:convert';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/app_config.dart';
import '../../data/models/recognition_backend.dart';
import '../../nsl/landmark_diagnostics.dart';
import '../../nsl/recognizer.dart';
import '../providers/providers.dart';

/// On-device tuning and diagnostics (spec section 8), reached by long-pressing
/// the Live screen's title so it stays out of the way during a demo.
///
/// The sliders exist because the landmark model has no NONE class: any visible
/// hand produces a prediction, so the confidence gate is the only defence
/// against junk between characters, and its value can only be measured live.
class NslDebugScreen extends ConsumerStatefulWidget {
  const NslDebugScreen({super.key});

  @override
  ConsumerState<NslDebugScreen> createState() => _NslDebugScreenState();
}

class _NslDebugScreenState extends ConsumerState<NslDebugScreen> {
  /// Repaints the live figures without rebuilding the whole tree on every camera
  /// frame -- they are read straight from the recogniser, not provider state.
  late final Ticker _ticker = Ticker(() {
    if (mounted) setState(() {});
  });

  @override
  void initState() {
    super.initState();
    _ticker.start();
  }

  @override
  void dispose() {
    _ticker.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = ref.read(sentencePipelineProvider.notifier);
    final pipeline = ref.watch(sentencePipelineProvider);
    final recognizer = ref.watch(recognizerProvider);
    final backend = ref.watch(recognitionBackendProvider);
    final backendNotice = ref.watch(recognitionBackendNoticeProvider);
    final parity = ref.watch(parityResultProvider);
    final live = ref.watch(liveResultProvider);
    final defaultConfidenceThreshold =
      backend == RecognitionBackend.landmark
        ? AppConfig.landmarkConfidenceThreshold
        : AppConfig.sentenceConfidenceThreshold;
    final topLabel = backend == RecognitionBackend.landmark
      ? (recognizer?.topLabel ?? '—')
      : (live.handDetected ? live.recognizedText : '—');
    final confidence = backend == RecognitionBackend.landmark
      ? recognizer?.topConf
      : live.confidence;
    final skipReason = backend == RecognitionBackend.landmark
      ? (recognizer?.lastSkipReason ?? SkipReason.none).label
      : !live.handDetected
        ? 'No palm detected'
        : live.confidence < controller.confidenceThreshold
          ? 'Below threshold'
          : 'OK';

    return Scaffold(
      appBar: AppBar(title: const Text('NSL Debug')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _Section(
            title: 'Parity gate (spec section 6)',
            child: parity.when(
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Row(children: [
                  SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                  SizedBox(width: 12),
                  Text('Running 36 fixtures...'),
                ]),
              ),
              error: (e, _) => Text('FAILED TO RUN: $e',
                  style: TextStyle(color: theme.colorScheme.error)),
              data: (r) => Row(
                children: [
                  Icon(
                    r.pass ? Icons.check_circle_rounded : Icons.error_rounded,
                    color: r.pass ? Colors.green : theme.colorScheme.error,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(r.toString(),
                        style: theme.textTheme.bodySmall
                            ?.copyWith(fontFamily: 'monospace')),
                  ),
                ],
              ),
            ),
          ),
          _Section(
            title: 'Model',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SegmentedButton<RecognitionBackend>(
                  segments: [
                    for (final b in RecognitionBackend.values)
                      ButtonSegment(value: b, label: Text(b.label)),
                  ],
                  selected: {backend},
                  onSelectionChanged: (s) => ref
                      .read(recognitionBackendProvider.notifier)
                      .state = s.first,
                ),
                const SizedBox(height: 8),
                if (backendNotice != null) ...[
                  Text(
                    backendNotice,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.tertiary,
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                Text(
                  'Switching resets the stabilizer, so a partial hold from one '
                  'model never carries into the other.',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          _Section(
            title: 'Live',
            child: Column(
              children: [
                _Row('Top-1', topLabel),
                _Row('Confidence', confidence?.toStringAsFixed(3) ?? '—'),
                _Row('Hand detected', live.handDetected ? 'yes' : 'no'),
                _Row('Stability',
                    '${(controller.holdProgress * controller.stableFrameCount).round()}'
                    ' / ${controller.stableFrameCount}'),
                _Row('Skip reason', skipReason),
                if (backend == RecognitionBackend.landmark) ...[
                  const Divider(height: 20),
                  _DetectionRate(recognizer: recognizer),
                ],
              ],
            ),
          ),
          if (backend == RecognitionBackend.landmark) ...[
            _Section(
              title: 'Handedness / lens',
              child: _HandednessPanel(recognizer: recognizer),
            ),
            _Section(
              title: 'Landmark geometry (camera-path check)',
              child: _GeometryPanel(recognizer: recognizer),
            ),
          ],
          _Section(
            title: 'Tuning',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _SliderRow(
                  label: 'Confidence threshold',
                  value: controller.confidenceThreshold,
                  min: 0.5,
                  max: 0.95,
                  divisions: 45,
                  display: controller.confidenceThreshold.toStringAsFixed(2),
                  onChanged: (v) {
                    controller.setTuning(confidenceThreshold: v);
                    setState(() {});
                  },
                ),
                _SliderRow(
                  label: 'Stable frames',
                  value: controller.stableFrameCount.toDouble(),
                  min: 3,
                  max: 15,
                  divisions: 12,
                  display: '${controller.stableFrameCount}'
                      '  (~${(controller.stableFrameCount * AppConfig.frameSampleInterval.inMilliseconds)}ms hold)',
                  onChanged: (v) {
                    controller.setTuning(stableFrameCount: v.round());
                    setState(() {});
                  },
                ),
                const SizedBox(height: 4),
                Text(
                  'Defaults (${AppConfig.landmarkConfidenceThreshold} / '
                  '${AppConfig.stableFrameCount}) were tuned against the image '
                  'model. The landmark model\'s softmax is more peaked, so it '
                  'likely crosses any given threshold on more frames — expect '
                  'to raise the gate rather than lower it. Changes apply '
                  'immediately and are not persisted.',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    icon: const Icon(Icons.restart_alt_rounded),
                    label: const Text('Reset to defaults'),
                    onPressed: () {
                      controller.setTuning(
                        confidenceThreshold: defaultConfidenceThreshold,
                        stableFrameCount: AppConfig.stableFrameCount,
                      );
                      setState(() {});
                    },
                  ),
                ),
              ],
            ),
          ),
          _Section(
            title: 'Output',
            child: Column(
              children: [
                _Row('Letters', pipeline.letters.isEmpty ? '—' : pipeline.letters),
                _Row('Sentence',
                    pipeline.sentence.isEmpty ? '—' : pipeline.sentence),
                _Row('Status', pipeline.status.name),
                const SizedBox(height: 8),
                Row(
                  children: [
                    OutlinedButton(
                      onPressed: controller.hasBufferedLetters
                          ? controller.undoLastLetter
                          : null,
                      child: const Text('Backspace'),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: controller.clearAll,
                      child: const Text('Clear'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Detection rate with an explicit not-yet-meaningful state.
///
/// The first number to check when live accuracy disappoints: high with poor
/// accuracy points at the classifier or MediaPipe drift from the 0.10.14 used in
/// training, low at framing, lighting or distance.
class _DetectionRate extends StatelessWidget {
  const _DetectionRate({required this.recognizer});

  final Recognizer? recognizer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final samples = recognizer?.detectionSamples ?? 0;
    final rate = recognizer?.detectionRate ?? 0;

    // Below a handful of frames the ratio swings wildly and reads as signal.
    final converged = samples >= 10;
    final color = !converged
        ? theme.colorScheme.onSurfaceVariant
        : rate >= 0.8
            ? Colors.green
            : rate >= 0.4
                ? Colors.orange
                : theme.colorScheme.error;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Detection rate', style: theme.textTheme.bodyMedium),
            const Spacer(),
            Text(
              converged
                  ? '${(rate * 100).toStringAsFixed(0)}%  (n=$samples)'
                  : 'warming up (n=$samples)',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: color, fontWeight: FontWeight.w600),
            ),
          ],
        ),
        const SizedBox(height: 4),
        LinearProgressIndicator(
          value: converged ? rate : null,
          color: color,
          backgroundColor: theme.colorScheme.surfaceContainerHighest,
        ),
        const SizedBox(height: 4),
        Text(
          'Frames where MediaPipe returned a hand, over the last 60. Counts '
          'detection, not successful classification — a degenerate hand counts '
          'here and shows under skip reason.',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            child,
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.bodyMedium),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.display,
    required this.onChanged,
  });

  final String label;
  final double value, min, max;
  final int divisions;
  final String display;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(label, style: theme.textTheme.bodyMedium),
            const Spacer(),
            Text(display,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w600)),
          ],
        ),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          onChanged: onChanged,
        ),
      ],
    );
  }
}

/// Minimal repaint driver, so the live figures update without the recogniser
/// having to push every frame through provider state.
class Ticker {
  Ticker(this.onTick);

  final VoidCallback onTick;
  bool _running = false;

  void start() {
    if (_running) return;
    _running = true;
    _schedule();
  }

  void stop() => _running = false;

  void _schedule() {
    if (!_running) return;
    Future<void>.delayed(const Duration(milliseconds: 200), () {
      if (!_running) return;
      onTick();
      _schedule();
    });
  }
}


/// Compares the live landmark cloud against the training fixture -- the
/// diagnostic for a build that passes parity but predicts badly live. The parity
/// gate never exercises the camera path, so a difference in resolution, aspect
/// ratio, rotation or mirroring shifts every feature with no error raised.
class _GeometryPanel extends StatelessWidget {
  const _GeometryPanel({required this.recognizer});

  final Recognizer? recognizer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final g = LandmarkGeometry.of(recognizer?.lastRawLandmarks);

    if (g == null) {
      return Text('Hold a hand in frame to measure.',
          style: theme.textTheme.bodySmall);
    }

    final ratioWrong = LandmarkReference.ratioLooksWrong(g.spreadRatio);
    final angleOff = (g.pointingAngleDeg - LandmarkReference.pointingAngleDeg)
        .abs();
    final angleWrong = angleOff > 45;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Cmp('x spread', g.xSpread, LandmarkReference.xSpread, false),
        _Cmp('y spread', g.ySpread, LandmarkReference.ySpread, false),
        _Cmp('x/y ratio', g.spreadRatio, LandmarkReference.spreadRatio,
            ratioWrong),
        _Cmp('pointing angle', g.pointingAngleDeg,
            LandmarkReference.pointingAngleDeg, angleWrong,
            unit: '°'),
        _Row('z range', g.zRange.toStringAsFixed(3)),
        const Divider(height: 18),
        Text('wrist -> middle-MCP  (landmark[9] - landmark[0])',
            style: theme.textTheme.bodySmall),
        const SizedBox(height: 4),
        _Cmp('  dx', g.wristToMcpDx, LandmarkReference.wristToMcpDx, false),
        _Cmp('  dy', g.wristToMcpDy, LandmarkReference.wristToMcpDy, false),
        const SizedBox(height: 8),
        if (ratioWrong || angleWrong)
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: theme.colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              [
                if (ratioWrong)
                  'Aspect mismatch: the live hand is shaped differently from '
                      'training. MediaPipe normalises x by frame width and y by '
                      'frame height, so a different frame aspect ratio distorts '
                      'every feature. Features.compute is scale-invariant but '
                      'NOT aspect-invariant.',
                if (angleWrong)
                  'Rotation mismatch: the hand points a different way than '
                      'training saw. Check the sensorOrientation passed to '
                      'processFrame, and whether the front camera is mirroring '
                      '(meta.json says mirror_left=false).',
              ].join('\n\n'),
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onErrorContainer),
            ),
          )
        else
          Text(
            'Live geometry resembles training. If predictions are still wrong, '
            'the camera path is not the cause — suspect MediaPipe version '
            'drift from the 0.10.14 used in training (spec section 9), which '
            'needs a re-extract and retrain rather than an app change.',
            style: theme.textTheme.bodySmall,
          ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            icon: const Icon(Icons.copy_all_rounded),
            label: const Text('Copy raw landmarks'),
            onPressed: () {
              final lm = recognizer?.lastRawLandmarks;
              if (lm == null) return;
              Clipboard.setData(ClipboardData(text: jsonEncode(lm)));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('21 landmarks copied as JSON'),
                  duration: Duration(seconds: 2),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// One live-vs-training row, highlighted when the two disagree materially.
class _Cmp extends StatelessWidget {
  const _Cmp(this.label, this.live, this.reference, this.bad, {this.unit = ''});

  final String label;
  final double live, reference;
  final bool bad;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Text(label, style: theme.textTheme.bodyMedium),
          const Spacer(),
          Text(
            '${live.toStringAsFixed(2)}$unit',
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: bad ? theme.colorScheme.error : null,
            ),
          ),
          Text('  vs  ${reference.toStringAsFixed(2)}$unit',
              style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}

/// Mirroring and lens controls, for isolating a handedness mismatch between
/// training and the live camera. The plugin returns raw sensor-space landmarks,
/// so a front sensor turns a right hand into a geometrically left one and
/// `Features.compute` is not mirror-invariant. The tell: symmetric handshapes
/// work, asymmetric ones only with the opposite hand, some only rotated.
class _HandednessPanel extends ConsumerWidget {
  const _HandednessPanel({required this.recognizer});

  final Recognizer? recognizer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final r = recognizer;
    final camera = ref.watch(cameraServiceProvider);
    final lens = camera.lensDirection;

    if (r == null) {
      return Text('Model still loading.', style: theme.textTheme.bodySmall);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('MIRROR X  (x -> 1.0 - x on all 21 landmarks)',
            style: theme.textTheme.bodyMedium),
        const SizedBox(height: 6),
        SegmentedButton<MirrorMode>(
          segments: [
            for (final m in MirrorMode.values)
              ButtonSegment(value: m, label: Text(m.label)),
          ],
          selected: {r.mirrorMode},
          // No explicit rebuild needed: the 200ms ticker repaints this panel.
          onSelectionChanged: (s) => r.mirrorMode = s.first,
        ),
        const SizedBox(height: 12),
        Text('Camera lens', style: theme.textTheme.bodyMedium),
        const SizedBox(height: 6),
        SegmentedButton<CameraLensDirection>(
          segments: const [
            ButtonSegment(
                value: CameraLensDirection.back, label: Text('Back')),
            ButtonSegment(
                value: CameraLensDirection.front, label: Text('Front')),
          ],
          selected: {lens ?? CameraLensDirection.back},
          onSelectionChanged: (s) async {
            await camera.selectLens(s.first);
            // Tell the Live screen to re-resolve the mirroring rule.
            ref.read(lensGenerationProvider.notifier).state++;
          },
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Row('Active lens', lens?.name ?? 'unknown'),
              _Row('Mirror in force', r.mirrorApplied ? 'YES' : 'no'),
              const SizedBox(height: 6),
              Text(
                'Test all four combinations (back/front x on/off) on the same '
                'set of signs. Include at least one asymmetric handshape -- '
                'symmetric ones look identical mirrored and prove nothing.',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
