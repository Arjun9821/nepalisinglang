import 'dart:math' as math;

import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

/// On-device hand localisation with MediaPipe's palm-detection model, used to
/// crop the live frame to the hand before the NSL classifier sees it: the
/// classifier was trained on tightly-framed shots, and a whole-room frame leaves
/// the hand tiny and off-centre, which kept live confidence at ~10-20%.
///
/// Letterbox to 192x192 -> palm detector -> decode against SSD anchors -> expand
/// the palm box into a hand ROI via the wrist->middle-finger vector -> crop that
/// ROI's axis-aligned bounds out of the full-resolution frame. The crop is not
/// rotated upright, since the training photos are in their natural orientation.
class HandCropper {
  HandCropper._(this._interpreter, this._anchors);

  final Interpreter _interpreter;
  final List<_Anchor> _anchors;

  /// Palm detector input is a fixed 192x192 square.
  static const int inputSize = 192;

  /// Minimum sigmoid score for a palm detection to be trusted.
  static const double _scoreThreshold = 0.5;

  /// How much to grow the palm box into a whole-hand ROI. MediaPipe's default
  /// for the hand pipeline; lower crops tighter but risks clipping fingers.
  static const double _roiScale = 2.6;

  /// Shift of the ROI centre towards the fingertips, in palm-box long sides.
  static const double _roiShiftY = -0.5;

  /// Builds a cropper around a loaded palm-detection interpreter address, which
  /// is all that crosses into the recognition isolate.
  static HandCropper fromAddress(int interpreterAddress) {
    return HandCropper._(
      Interpreter.fromAddress(interpreterAddress),
      _generateAnchors(),
    );
  }

  /// Returns a native-resolution crop framing the hand in [frame], or null when
  /// no hand is confidently detected -- the caller falls back to the whole frame.
  img.Image? cropHand(img.Image frame) {
    final w = frame.width;
    final h = frame.height;

    // --- 1. Letterbox into a 192x192 square, aspect preserved. ---
    final scale = math.min(inputSize / w, inputSize / h);
    final nw = (w * scale).round();
    final nh = (h * scale).round();
    final offsetX = ((inputSize - nw) / 2).floor();
    final offsetY = ((inputSize - nh) / 2).floor();

    final resized = img.copyResize(
      frame,
      width: nw,
      height: nh,
      interpolation: img.Interpolation.linear,
    );
    final canvas = img.Image(width: inputSize, height: inputSize, numChannels: 3);
    img.compositeImage(canvas, resized, dstX: offsetX, dstY: offsetY);

    // Normalise to [0, 1] -- [0, 255] and [-1, 1] both produce garbage boxes.
    final input = List.generate(
      1,
      (_) => List.generate(
        inputSize,
        (y) => List.generate(inputSize, (x) {
          final p = canvas.getPixel(x, y);
          return [p.r / 255.0, p.g / 255.0, p.b / 255.0];
        }),
      ),
    );

    // --- 2. Run the palm detector. ---
    // boxes [1, 2016, 18] + scores [1, 2016, 1], keyed off the last dimension so
    // a re-export cannot silently swap them.
    final out0Shape = _interpreter.getOutputTensor(0).shape;
    final boxesIsFirst = out0Shape.last == 18;
    final boxesIdx = boxesIsFirst ? 0 : 1;
    final scoresIdx = boxesIsFirst ? 1 : 0;

    final numBoxes = _anchors.length;
    final rawBoxes = List.generate(
      1,
      (_) => List.generate(numBoxes, (_) => List<double>.filled(18, 0.0)),
    );
    final rawScores = List.generate(
      1,
      (_) => List.generate(numBoxes, (_) => List<double>.filled(1, 0.0)),
    );
    final outputs = <int, Object>{boxesIdx: rawBoxes, scoresIdx: rawScores};
    _interpreter.runForMultipleInputs([input], outputs);

    // --- 3. Decode + pick the single best detection. ---
    final best = _selectBestDetection(rawBoxes[0], rawScores[0]);
    if (best == null) return null;

    // --- 4. Letterbox coords -> frame pixels, then palm box -> hand ROI. ---
    double unX(double nx) => (nx * inputSize - offsetX) / scale;
    double unY(double ny) => (ny * inputSize - offsetY) / scale;

    final cx = unX(best.cx);
    final cy = unY(best.cy);
    final boxW = best.w * inputSize / scale;
    final boxH = best.h * inputSize / scale;

    // Wrist (keypoint 0) -> middle-finger MCP (keypoint 2) sets hand angle.
    final wristX = unX(best.keypoints[0]);
    final wristY = unY(best.keypoints[1]);
    final midX = unX(best.keypoints[2]);
    final midY = unY(best.keypoints[3]);
    final angle = math.pi / 2 - math.atan2(-(midY - wristY), midX - wristX);
    final sinA = math.sin(angle);
    final cosA = math.cos(angle);

    final longSide = math.max(boxW, boxH);
    // Shift the ROI centre towards the fingers, in the rotated frame.
    final roiCx = cx + (-sinA * _roiShiftY) * longSide;
    final roiCy = cy + (cosA * _roiShiftY) * longSide;
    final half = longSide * _roiScale / 2;

    // Axis-aligned bounding box of the rotated ROI square.
    var minX = double.infinity, minY = double.infinity;
    var maxX = -double.infinity, maxY = -double.infinity;
    for (final corner in const [
      [-1.0, -1.0],
      [1.0, -1.0],
      [1.0, 1.0],
      [-1.0, 1.0],
    ]) {
      final dx = corner[0] * half;
      final dy = corner[1] * half;
      final rx = roiCx + cosA * dx - sinA * dy;
      final ry = roiCy + sinA * dx + cosA * dy;
      minX = math.min(minX, rx);
      minY = math.min(minY, ry);
      maxX = math.max(maxX, rx);
      maxY = math.max(maxY, ry);
    }

    // --- 5. Clamp to the frame and crop. ---
    final cropX = minX.floor().clamp(0, w - 1);
    final cropY = minY.floor().clamp(0, h - 1);
    final cropRight = maxX.ceil().clamp(cropX + 1, w);
    final cropBottom = maxY.ceil().clamp(cropY + 1, h);
    final cropW = cropRight - cropX;
    final cropH = cropBottom - cropY;
    if (cropW < 2 || cropH < 2) return null;

    return img.copyCrop(
      frame,
      x: cropX,
      y: cropY,
      width: cropW,
      height: cropH,
    );
  }

  /// Decodes every candidate, keeps those above [_scoreThreshold] and returns
  /// the highest-scoring one. `max_num_hands = 1`, so full NMS is unnecessary.
  _Detection? _selectBestDetection(
    List<List<double>> boxes,
    List<List<double>> scores,
  ) {
    _Detection? best;
    var bestScore = _scoreThreshold;
    for (var i = 0; i < _anchors.length; i++) {
      final logit = scores[i][0].clamp(-100.0, 100.0);
      final score = 1.0 / (1.0 + math.exp(-logit));
      if (score < bestScore) continue;

      final a = _anchors[i];
      final raw = boxes[i];
      final cx = raw[0] / inputSize + a.x;
      final cy = raw[1] / inputSize + a.y;
      final bw = raw[2] / inputSize;
      final bh = raw[3] / inputSize;
      // Keypoints share the anchor offset; only 0 (wrist) and 2 (MCP) are used.
      final k0x = raw[4] / inputSize + a.x;
      final k0y = raw[5] / inputSize + a.y;
      final k2x = raw[8] / inputSize + a.x;
      final k2y = raw[9] / inputSize + a.y;

      bestScore = score;
      best = _Detection(cx, cy, bw, bh, [k0x, k0y, k2x, k2y]);
    }
    return best;
  }

  /// The 2016 SSD anchors. Order (layer -> row -> col -> repeat) must match the
  /// model's output order; `fixed_anchor_size` means only the centre matters.
  static List<_Anchor> _generateAnchors() {
    const strides = [8, 16, 16, 16];
    const numLayers = 4;
    final anchors = <_Anchor>[];
    var layerId = 0;
    while (layerId < numLayers) {
      var last = layerId;
      var repeats = 0;
      while (last < numLayers && strides[last] == strides[layerId]) {
        // aspect_ratio 1.0 + interpolated_scale_aspect_ratio 1.0 = 2 per layer.
        repeats += 2;
        last++;
      }
      final stride = strides[layerId];
      final featureMap = (inputSize / stride).ceil();
      for (var y = 0; y < featureMap; y++) {
        final yCenter = (y + 0.5) / featureMap;
        for (var x = 0; x < featureMap; x++) {
          final xCenter = (x + 0.5) / featureMap;
          for (var r = 0; r < repeats; r++) {
            anchors.add(_Anchor(xCenter, yCenter));
          }
        }
      }
      layerId = last;
    }
    return anchors;
  }
}

class _Anchor {
  const _Anchor(this.x, this.y);
  final double x;
  final double y;
}

class _Detection {
  _Detection(this.cx, this.cy, this.w, this.h, this.keypoints);
  final double cx;
  final double cy;
  final double w;
  final double h;

  /// Flat [k0x, k0y, k2x, k2y] in letterbox-normalised coordinates.
  final List<double> keypoints;
}
