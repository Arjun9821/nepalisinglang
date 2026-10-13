import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:permission_handler/permission_handler.dart';

/// Thin wrapper around the `camera` plugin.
///
/// A single shared instance, because only one physical camera can be open at a
/// time and only the active tab should hold it. [initialize]/[switchCamera]/
/// [stop] funnel through [_serialized] so a release-then-acquire pair from one
/// tab switch cannot race as two concurrent native opens -- the race behind
/// switching tabs breaking the camera.
///
/// [startStream] hands off the raw [CameraImage] and does no conversion itself:
/// blocking here starves the platform channel and crashes the camera HAL.
class CameraService {
  CameraController? _controller;
  List<CameraDescription> _cameras = [];
  int _selectedCameraIndex = 0;

  Future<void> _lock = Future.value();
  bool _isStreaming = false;
  DateTime? _lastSampleTime;

  CameraController? get controller => _controller;
  bool get isInitialized => _controller?.value.isInitialized ?? false;
  bool get isStreaming => _isStreaming;

  int get sensorOrientation => _cameras.isEmpty
      ? 0
      : _cameras[_selectedCameraIndex].sensorOrientation;

  /// Which physical lens is open, or null before [initialize]. The landmark
  /// pipeline needs it: the front sensor mirrors the image, turning a right hand
  /// into a geometrically left one. See `Recognizer.mirrorApplied`.
  CameraLensDirection? get lensDirection => _cameras.isEmpty
      ? null
      : _cameras[_selectedCameraIndex].lensDirection;

  /// Opens a specific lens rather than cycling as [switchCamera] does. No-op
  /// when it is already open or the device lacks it.
  Future<void> selectLens(CameraLensDirection direction) =>
      _serialized(() async {
        if (_cameras.isEmpty) return;
        if (_cameras[_selectedCameraIndex].lensDirection == direction) return;
        final index =
            _cameras.indexWhere((c) => c.lensDirection == direction);
        if (index < 0) return;
        _selectedCameraIndex = index;
        await _openController(_cameras[index]);
      });

  /// Requests permission and initializes the controller with the front camera
  /// (falling back to the back camera or whatever exists). Safe to call again
  /// after [stop].
  Future<void> initialize() => _serialized(() async {
        final status = await Permission.camera.request();
        if (!status.isGranted) {
          throw CameraException(
            'PERMISSION_DENIED',
            'Camera permission was not granted.',
          );
        }

        if (_cameras.isEmpty) {
          _cameras = await availableCameras();
        }
        if (_cameras.isEmpty) {
          throw CameraException('NO_CAMERA', 'No cameras available on device.');
        }

        if (_controller == null) {
          _selectedCameraIndex = _cameras.indexWhere(
            (c) => c.lensDirection == CameraLensDirection.front,
          );
          if (_selectedCameraIndex < 0) {
            _selectedCameraIndex = _cameras.indexWhere(
              (c) => c.lensDirection == CameraLensDirection.back,
            );
          }
          if (_selectedCameraIndex < 0) _selectedCameraIndex = 0;
          await _openController(_cameras[_selectedCameraIndex]);
        }
      });

  Future<void> _openController(CameraDescription description) async {
    await _disposeController();
    _controller = CameraController(
      description,
      ResolutionPreset.low,
      enableAudio: false,
      imageFormatGroup: defaultTargetPlatform == TargetPlatform.iOS
          ? ImageFormatGroup.bgra8888
          : ImageFormatGroup.yuv420,
    );
    await _controller!.initialize();
  }

  /// Toggles between front and back camera.
  Future<void> switchCamera() => _serialized(() async {
        if (_cameras.length < 2) return;
        _selectedCameraIndex = (_selectedCameraIndex + 1) % _cameras.length;
        await _openController(_cameras[_selectedCameraIndex]);
      });

  /// Releases the camera hardware entirely, so another screen can acquire it.
  Future<void> stop() => _serialized(_disposeController);

  Future<void> _disposeController() async {
    _isStreaming = false;
    final controller = _controller;
    _controller = null;
    if (controller != null) {
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
      await controller.dispose();
    }
  }

  /// Starts sampling live frames, calling [onFrame] with the raw [CameraImage]
  /// and sensor orientation no more often than [sampleInterval]. Faster frames
  /// are dropped cheaply, since this callback does no conversion work.
  void startStream(
    void Function(CameraImage image, int sensorOrientation) onFrame, {
    Duration sampleInterval = const Duration(milliseconds: 500),
  }) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (_isStreaming) return;
    _isStreaming = true;
    _lastSampleTime = null;

    controller.startImageStream((CameraImage image) {
      final now = DateTime.now();
      if (_lastSampleTime != null &&
          now.difference(_lastSampleTime!) < sampleInterval) {
        return;
      }
      _lastSampleTime = now;
      onFrame(image, sensorOrientation);
    });
  }

  Future<void> stopStream() async {
    _isStreaming = false;
    final controller = _controller;
    if (controller != null && controller.value.isStreamingImages) {
      await controller.stopImageStream();
    }
  }

  /// Runs [operation]s one at a time in call order -- see the class doc.
  Future<T> _serialized<T>(Future<T> Function() operation) {
    final result = _lock.then((_) => operation());
    _lock = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<void> dispose() => _serialized(_disposeController);
}
