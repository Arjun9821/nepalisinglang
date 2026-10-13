import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hand_landmarker/hand_landmarker.dart';

import '../../core/config/app_config.dart';
import '../../core/utils/constants.dart';
import '../../core/utils/nsl_labels.dart';
import '../../data/models/recognition_backend.dart';
import '../../nsl/model.dart';
import '../providers/providers.dart';
import '../widgets/camera_preview_card.dart';
import '../widgets/live_prediction_strip.dart';
import '../widgets/sentence_card.dart';
import 'debug_screen.dart';

/// Live landmark recognition (spec section 7).
///
/// Camera access goes through the shared `CameraService`, gated on this being
/// the active tab; the screen owns no [CameraController] of its own.
///
/// Per-frame results go to [liveResultProvider] for the raw readout and to
/// [sentencePipelineProvider], which owns all gating, debouncing and boundary
/// detection. This screen holds no thresholds.
class LiveScreen extends ConsumerStatefulWidget {
  const LiveScreen({super.key});

  @override
  ConsumerState<LiveScreen> createState() => _LiveScreenState();
}

class _LiveScreenState extends ConsumerState<LiveScreen>
    with WidgetsBindingObserver {
  static const _previewHeightFraction = 0.42;

  HandLandmarkerPlugin? _plugin;
  StreamSubscription<List<Hand>>? _sub;
  ProviderSubscription<int>? _tabSubscription;

  String? _error;
  bool _isActive = false;
  bool _appIsResumed = true;
  bool _imageModelReady = false;
  bool _isRecognizing = false;
  int _activationGeneration = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycleState = WidgetsBinding.instance.lifecycleState;
    _appIsResumed =
        lifecycleState == null || lifecycleState == AppLifecycleState.resumed;
    _tabSubscription = ref.listenManual<int>(
      bottomNavIndexProvider,
      (_, __) => _syncCameraActivity(),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncCameraActivity();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final resumed = state == AppLifecycleState.resumed;
    if (_appIsResumed == resumed) return;
    _appIsResumed = resumed;
    _syncCameraActivity();
  }

  void _syncCameraActivity() {
    if (!mounted) return;
    if (_shouldBeActive) {
      unawaited(_activate());
    } else {
      unawaited(_deactivate());
    }
  }

  bool get _shouldBeActive =>
      _appIsResumed &&
      ref.read(bottomNavIndexProvider) == AppConstants.liveTabIndex;

  bool _isCurrentActivation(int generation) =>
      mounted &&
      _isActive &&
      generation == _activationGeneration &&
      _shouldBeActive;

  /// Created once for the widget's lifetime rather than per activation:
  /// `landmarkStream` is backed by a static `EventChannel`, so churning
  /// instances would keep tearing down the same global subscription.
  void _ensurePlugin(NslModel model) {
    if (_plugin != null) return;
    _plugin = HandLandmarkerPlugin.create(
      numHands: 1,
      // From meta.json, not AppConfig: an extraction parameter training used,
      // not UX tuning. Changing it shifts the input distribution.
      minHandDetectionConfidence: model.detConf,
      delegate: HandLandmarkerDelegate.gpu,
    );
    _sub = _plugin!.landmarkStream.listen(_onHands);
  }

  Future<void> _initializeLandmarkBackend(int generation) async {
    try {
      final model = await ref.read(nslModelProvider.future);
      if (!_isCurrentActivation(generation)) return;
      _ensurePlugin(model);
      ref.read(recognitionBackendNoticeProvider.notifier).state = null;
    } catch (e) {
      if (!_isCurrentActivation(generation)) return;
      debugPrint(
        '[NSL] MediaPipe landmark backend unavailable; '
        'falling back to the TFLite image backend: $e',
      );
      ref.read(recognitionBackendNoticeProvider.notifier).state =
          'Landmark mode is unavailable on this device. Image mode is active.';
      ref.read(recognitionBackendProvider.notifier).state =
          RecognitionBackend.image;
    }
  }

  Future<void> _activate() async {
    if (_isActive || !_shouldBeActive) return;
    _isActive = true;
    final generation = ++_activationGeneration;
    final cameraService = ref.read(cameraServiceProvider);
    try {
      await cameraService.initialize();
      if (!_isCurrentActivation(generation)) return;
      if (ref.read(recognitionBackendProvider) == RecognitionBackend.landmark) {
        await _initializeLandmarkBackend(generation);
        if (!_isCurrentActivation(generation)) return;
      }
      _syncLens();
      setState(() => _error = null);
      ref.read(sentencePipelineProvider.notifier).start();
      _startCameraStream();
    } catch (e) {
      if (generation != _activationGeneration) return;
      _isActive = false;
      ref.read(sentencePipelineProvider.notifier).stop();
      ref.read(recognizerProvider)?.reset();
      try {
        await cameraService.stopStream();
        await cameraService.stop();
      } catch (_) {}
      if (mounted) setState(() => _error = _friendlyCameraError(e));
    }
  }

  String _friendlyCameraError(Object error) {
    if (error is CameraException) {
      return switch (error.code) {
        'PERMISSION_DENIED' ||
        'CameraAccessDenied' =>
          'Camera permission is off. Allow camera access in Android Settings, then return to Live.',
        'NO_CAMERA' => 'No camera was found on this device.',
        'CameraAccessDeniedWithoutPrompt' =>
          'Camera access is blocked. Allow it in Android Settings, then return to Live.',
        'CameraAccessRestricted' =>
          'Camera access is restricted on this device.',
        _ =>
          'Could not start the camera. Close other camera apps and try again.',
      };
    }
    return 'Could not start the camera. Close other camera apps and try again.';
  }

  void _showRecognitionLimits() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('What this app recognizes'),
        content: Text(
          'SignSathi recognizes 36 single-hand, static Nepali fingerspelled '
          'consonant characters from the camera. It can combine recognized '
          'characters into text, but it does not recognize dynamic signs, '
          'two-hand signs, or translate all of Nepali Sign Language.\n\n'
          'Hold one sign steadily in view; good lighting and a clear hand '
          'image help recognition.\n\n'
          'Supported characters:\n${NslLabels.characters.join('  ')}\n\n'
          'The chart also shows ${NslLabels.chartOnlyCharacter} (SHRA), which '
          'is not included in this 36-class model.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _deactivate() async {
    if (!_isActive) return;
    _isActive = false;
    _activationGeneration++;
    // Losing the camera flushes whatever was half-signed, same as Offline.
    ref.read(sentencePipelineProvider.notifier).stop();
    ref.read(recognizerProvider)?.reset();
    final cameraService = ref.read(cameraServiceProvider);
    await cameraService.stopStream();
    await cameraService.stop();
    if (mounted) setState(() {});
  }

  void _handleFrame(CameraImage image, int sensorOrientation) {
    if (!_isActive) return;
    switch (ref.read(recognitionBackendProvider)) {
      case RecognitionBackend.landmark:
        // Fire and forget; results arrive asynchronously on landmarkStream.
        _plugin?.processFrame(image, sensorOrientation);
      case RecognitionBackend.image:
        _handleImageBackendFrame(image, sensorOrientation);
    }
  }

  Future<void> _handleImageBackendFrame(
      CameraImage image, int sensorOrientation) async {
    if (_isRecognizing) return;
    _isRecognizing = true;
    try {
      final repository = ref.read(offlineRecognitionRepositoryProvider);
      if (!_imageModelReady) {
        await repository.initialize();
        _imageModelReady = true;
      }
      final result = await repository.recognizeFrame(image, sensorOrientation);
      if (!mounted || !_isActive) return;
      ref.read(liveResultProvider.notifier).state = result;
      ref.read(sentencePipelineProvider.notifier).ingest(result);
    } catch (e) {
      debugPrint('[NSL] image-backend frame failed: $e');
    } finally {
      _isRecognizing = false;
    }
  }

  void _onHands(List<Hand> hands) {
    if (!mounted || !_isActive) return;
    if (ref.read(recognitionBackendProvider) != RecognitionBackend.landmark) {
      return;
    }
    final recognizer = ref.read(recognizerProvider);
    if (recognizer == null) return;

    final result = recognizer.recognize(hands);
    // The unfiltered readout always updates; the pipeline decides separately
    // whether the frame is worth committing.
    ref.read(liveResultProvider.notifier).state = result;
    ref.read(sentencePipelineProvider.notifier).ingest(result);
  }

  /// Tells the recogniser which lens is open, so [MirrorMode.auto] can resolve.
  /// Called on every acquire and lens change: stale is the bug it exists to fix.
  void _syncLens() {
    final camera = ref.read(cameraServiceProvider);
    final lens = camera.lensDirection;
    final recognizer = ref.read(recognizerProvider);
    if (recognizer == null || lens == null) return;
    recognizer.isFrontLens = lens == CameraLensDirection.front;
    debugPrint(
      '[NSL] lens=${lens.name} sensorOrientation=${camera.sensorOrientation} '
      'mirrorMode=${recognizer.mirrorMode.name} '
      '-> mirrorApplied=${recognizer.mirrorApplied}',
    );
  }

  void _startCameraStream() {
    ref.read(cameraServiceProvider).startStream(
          _handleFrame,
          // Must match the interval stableFrameCount was calibrated against:
          // raw 30fps would make a 3-frame hold ~100ms, not ~450ms.
          sampleInterval: AppConfig.frameSampleInterval,
        );
  }

  void _onLensGenerationChanged() {
    _syncLens();
    if (_isCurrentActivation(_activationGeneration)) {
      // selectLens() opens a new controller, which also ends the old stream.
      _startCameraStream();
    }
  }

  Future<void> _switchCamera() async {
    final generation = _activationGeneration;
    if (!_isCurrentActivation(generation)) return;
    final cameraService = ref.read(cameraServiceProvider);
    try {
      await cameraService.switchCamera();
      if (!_isCurrentActivation(generation)) return;
      _syncLens();
      setState(() => _error = null);
      _startCameraStream();
    } catch (e) {
      if (_isCurrentActivation(generation)) {
        setState(() => _error = _friendlyCameraError(e));
      }
    }
  }

  void _openDebug() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const NslDebugScreen()),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tabSubscription?.close();
    _activationGeneration++;
    _sub?.cancel();
    _plugin?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The debug screen can change the lens, which the mirroring rule depends on.
    ref.listen<int>(lensGenerationProvider, (_, __) {
      _onLensGenerationChanged();
    });

    // Swapping classifiers mid-utterance would otherwise carry one model's
    // partial hold into the other's prediction stream.
    ref.listen<RecognitionBackend>(recognitionBackendProvider, (_, next) {
      ref.read(recognizerProvider)?.reset();
      _imageModelReady = false;
      final pipeline = ref.read(sentencePipelineProvider.notifier);
      pipeline.stop();
      pipeline.setTuning(
        confidenceThreshold: next == RecognitionBackend.landmark
            ? AppConfig.landmarkConfidenceThreshold
            : AppConfig.sentenceConfidenceThreshold,
      );
      if (!_isActive) return;
      pipeline.start();
      if (next == RecognitionBackend.landmark && _plugin == null) {
        unawaited(_initializeLandmarkBackend(_activationGeneration));
      }
    });

    final cameraService = ref.watch(cameraServiceProvider);
    final modelAsync = ref.watch(nslModelProvider);
    final live = ref.watch(liveResultProvider);
    final pipeline = ref.watch(sentencePipelineProvider);
    final controller = ref.read(sentencePipelineProvider.notifier);
    final backend = ref.watch(recognitionBackendProvider);
    final backendNotice = ref.watch(recognitionBackendNoticeProvider);
    if (backend == RecognitionBackend.image) {
      ref.watch(offlineRecognitionRepositoryProvider);
    }

    return Scaffold(
      appBar: AppBar(
        // Long-press is the spec's hidden entry point to the debug screen.
        title: GestureDetector(
          onLongPress: _openDebug,
          child: const Text('Live Recognition'),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline_rounded),
            tooltip: 'Supported signs and limitations',
            onPressed: _showRecognitionLimits,
          ),
          IconButton(
            icon: Icon(pipeline.autoSpeak
                ? Icons.record_voice_over_rounded
                : Icons.voice_over_off_rounded),
            tooltip: pipeline.autoSpeak
                ? 'Auto-speak on — tap to mute'
                : 'Auto-speak off — tap to unmute',
            onPressed: controller.toggleAutoSpeak,
          ),
          IconButton(
            icon: const Icon(Icons.flip_camera_ios_rounded),
            tooltip: 'Switch camera',
            onPressed: _isActive ? _switchCamera : null,
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 8),
            CameraPreviewCard(
              controller: cameraService.controller,
              heightFraction: _previewHeightFraction,
              errorMessage: _error ??
                  (backend == RecognitionBackend.landmark
                      ? modelAsync.whenOrNull(
                          error: (e, _) => 'Model failed to load: $e',
                        )
                      : null),
              isActive: _isActive,
            ),
            const SizedBox(height: 12),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Column(
                  children: [
                    _BackendChip(backend: backend, onTap: _openDebug),
                    if (backendNotice != null) ...[
                      const SizedBox(height: 8),
                      _NoticeCard(message: backendNotice),
                    ],
                    const SizedBox(height: 8),
                    LivePredictionStrip(
                      label: live.recognizedText,
                      chartName: NslLabels.chartNameFor(live.recognizedText),
                      confidence: live.confidence,
                      handDetected: live.handDetected,
                      threshold: controller.confidenceThreshold,
                      holdProgress: controller.holdProgress,
                    ),
                    const SizedBox(height: 12),
                    SentenceCard(
                      state: pipeline,
                      backendLabel: controller.backendLabel,
                      hasBufferedLetters: controller.hasBufferedLetters,
                      onDone: controller.flushNow,
                      onClear: controller.clearAll,
                      onUndo: controller.undoLastLetter,
                      onSpeak: controller.speakOrStop,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoticeCard extends StatelessWidget {
  const _NoticeCard({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Card(
        margin: EdgeInsets.zero,
        color: Theme.of(context).colorScheme.tertiaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              const Icon(Icons.info_outline_rounded),
              const SizedBox(width: 8),
              Expanded(child: Text(message)),
            ],
          ),
        ),
      );
}

class _BackendChip extends StatelessWidget {
  const _BackendChip({required this.backend, required this.onTap});

  final RecognitionBackend backend;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: ActionChip(
        avatar: const Icon(Icons.memory_rounded, size: 18),
        label: Text('Model: ${backend.label}'),
        labelStyle: theme.textTheme.labelMedium,
        onPressed: onTap,
        tooltip: 'Open the debug screen to switch model and tune thresholds',
      ),
    );
  }
}
