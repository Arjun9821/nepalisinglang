import 'package:flutter/material.dart';

/// Draws a 21-point MediaPipe hand skeleton.
///
/// The landmarks come from `assets/parity.json`, one real training sample per
/// character, so these are the actual geometry the classifier was trained on
/// rather than illustrations. Points are normalised `[0, 1]` and rescaled to fit
/// the paint box with aspect preserved.
class HandSkeleton extends StatelessWidget {
  const HandSkeleton({
    super.key,
    required this.landmarks,
    this.strokeWidth = 2.0,
    this.pointRadius = 2.5,
    this.color,
  });

  /// 21 `[x, y, z]` triples. z is ignored.
  final List<List<double>> landmarks;
  final double strokeWidth;
  final double pointRadius;
  final Color? color;

  /// MediaPipe's standard hand connection map.
  static const List<List<int>> connections = [
    // thumb
    [0, 1], [1, 2], [2, 3], [3, 4],
    // index
    [0, 5], [5, 6], [6, 7], [7, 8],
    // middle
    [9, 10], [10, 11], [11, 12],
    // ring
    [13, 14], [14, 15], [15, 16],
    // pinky
    [0, 17], [17, 18], [18, 19], [19, 20],
    // palm
    [5, 9], [9, 13], [13, 17],
  ];

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _HandSkeletonPainter(
        landmarks: landmarks,
        color: color ?? Theme.of(context).colorScheme.primary,
        strokeWidth: strokeWidth,
        pointRadius: pointRadius,
      ),
      size: Size.infinite,
    );
  }
}

class _HandSkeletonPainter extends CustomPainter {
  _HandSkeletonPainter({
    required this.landmarks,
    required this.color,
    required this.strokeWidth,
    required this.pointRadius,
  });

  final List<List<double>> landmarks;
  final Color color;
  final double strokeWidth, pointRadius;

  @override
  void paint(Canvas canvas, Size size) {
    if (landmarks.length != 21 || size.isEmpty) return;

    // Fit the landmark cloud to the box, preserving aspect ratio: the hand
    // usually occupies only part of the source image.
    var minX = double.infinity, maxX = -double.infinity;
    var minY = double.infinity, maxY = -double.infinity;
    for (final p in landmarks) {
      if (p[0] < minX) minX = p[0];
      if (p[0] > maxX) maxX = p[0];
      if (p[1] < minY) minY = p[1];
      if (p[1] > maxY) maxY = p[1];
    }
    final spanX = (maxX - minX).abs();
    final spanY = (maxY - minY).abs();
    if (spanX == 0 || spanY == 0) return;

    const pad = 0.12;
    final usable = Size(size.width * (1 - pad), size.height * (1 - pad));
    final scale =
        (usable.width / spanX) < (usable.height / spanY)
            ? usable.width / spanX
            : usable.height / spanY;

    final drawnW = spanX * scale, drawnH = spanY * scale;
    final offsetX = (size.width - drawnW) / 2;
    final offsetY = (size.height - drawnH) / 2;

    Offset at(int i) => Offset(
          offsetX + (landmarks[i][0] - minX) * scale,
          offsetY + (landmarks[i][1] - minY) * scale,
        );

    final bonePaint = Paint()
      ..color = color.withValues(alpha: 0.55)
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    for (final c in HandSkeleton.connections) {
      canvas.drawLine(at(c[0]), at(c[1]), bonePaint);
    }

    final jointPaint = Paint()..color = color;
    for (var i = 0; i < 21; i++) {
      // The wrist is the origin Features.compute normalises against.
      canvas.drawCircle(at(i), i == 0 ? pointRadius * 1.8 : pointRadius,
          jointPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _HandSkeletonPainter old) =>
      old.landmarks != landmarks ||
      old.color != color ||
      old.strokeWidth != strokeWidth ||
      old.pointRadius != pointRadius;
}
