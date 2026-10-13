import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:meta/meta.dart';

/// Dart port of the OpenCV chain the classifier was trained with: grayscale ->
/// equalizeHist -> Gaussian adaptive threshold (11, 2, inverted) -> crop to the
/// foreground box -> INTER_AREA resize to 96x96 -> /255.
///
/// Each step reimplements OpenCV's actual algorithm so the two agree
/// pixel-for-pixel; deviating reintroduces the train/inference mismatch behind
/// 99% validation and near-random live accuracy. Pinned to `cv2` in
/// `test/nsl_preprocessor_test.dart`.
class NslPreprocessor {
  NslPreprocessor._();

  /// Classifier input side length; the model's tensor is `[1, 96, 96, 1]`.
  static const int inputSize = 96;

  /// `cv2.adaptiveThreshold` block size -- an absolute pixel window, so it is
  /// resolution sensitive (see [normalizedSourceMaxSide]).
  static const int _blockSize = 11;

  /// `cv2.adaptiveThreshold` C — subtracted from the local Gaussian mean.
  static const int _thresholdC = 2;

  /// Optional pre-step: downscale the crop so its longer side is at most this
  /// many pixels, or null to leave it native (what the guide specifies).
  ///
  /// The 11x11 threshold window is in raw pixels, so it acts as a silhouette
  /// extractor on a small dataset photo but a skin-texture filter on a 1080px
  /// phone crop. Set it to the training images' longer side if accuracy is poor.
  static const int? normalizedSourceMaxSide = null;

  /// Runs the chain on [source] and returns `inputSize * inputSize` float32
  /// values in `[0, 1]`, row-major -- fed straight to the interpreter as
  /// `[1, 96, 96, 1]`, with no channel tiling and no `[-1, 1]` rescaling.
  static Float32List preprocess(img.Image source) {
    final scaled = _normalizeSourceScale(source);
    final width = scaled.width;
    final height = scaled.height;

    // 1. Grayscale (OpenCV COLOR_BGR2GRAY weights).
    final gray = _toGrayscale(scaled);

    // 2. Global histogram equalization (cv2.equalizeHist, not CLAHE).
    _equalizeHistInPlace(gray);

    // 3. Gaussian adaptive threshold, inverted: hand -> 255, background -> 0.
    final binary = _adaptiveThresholdGaussianInv(gray, width, height);

    // 4. Crop to the bounding rectangle of the foreground.
    final box = _foregroundBoundingBox(binary, width, height);

    // 5 + 6. Area-interpolated resize to 96x96, normalized to [0, 1].
    return _resizeAreaToUnit(binary, width, height, box, inputSize);
  }

  /// See [normalizedSourceMaxSide]. A no-op when that knob is null.
  static img.Image _normalizeSourceScale(img.Image source) {
    const maxSide = normalizedSourceMaxSide;
    if (maxSide == null) return source;

    final longSide = math.max(source.width, source.height);
    if (longSide <= maxSide) return source;

    final scale = maxSide / longSide;
    return img.copyResize(
      source,
      width: math.max(1, (source.width * scale).round()),
      height: math.max(1, (source.height * scale).round()),
      // Averaging, to match the INTER_AREA-style downscale used elsewhere.
      interpolation: img.Interpolation.average,
    );
  }

  /// `cv2.cvtColor(..., COLOR_BGR2GRAY)` with OpenCV's fixed-point weights; the
  /// float form differs by a level on some pixels, enough to flip a threshold.
  static Uint8List _toGrayscale(img.Image source) {
    final width = source.width;
    final height = source.height;
    final rgb = source.getBytes(order: img.ChannelOrder.rgb);
    final gray = Uint8List(width * height);
    for (var i = 0, p = 0; i < gray.length; i++, p += 3) {
      gray[i] =
          (rgb[p] * 4899 + rgb[p + 1] * 9617 + rgb[p + 2] * 1868 + 8192) >> 14;
    }
    return gray;
  }

  /// `cv2.equalizeHist`: the cumulative histogram is scaled by
  /// `255 / (total - hist[first non-empty bin])` and the first occupied level
  /// maps to 0. The textbook `cdf * 255 / total` shifts every level.
  static void _equalizeHistInPlace(Uint8List gray) {
    const levels = 256;
    final hist = Int32List(levels);
    for (var i = 0; i < gray.length; i++) {
      hist[gray[i]]++;
    }

    var first = 0;
    while (first < levels && hist[first] == 0) {
      first++;
    }
    if (first == levels) return; // Empty image.

    final total = gray.length;
    if (hist[first] == total) {
      // OpenCV fills the whole image with the single occupied level.
      gray.fillRange(0, gray.length, first);
      return;
    }

    final lut = Uint8List(levels);
    final scale = (levels - 1) / (total - hist[first]);
    lut[first] = 0;
    var sum = 0;
    for (var i = first + 1; i < levels; i++) {
      sum += hist[i];
      lut[i] = _saturateCastUint8(sum * scale);
    }

    for (var i = 0; i < gray.length; i++) {
      gray[i] = lut[gray[i]];
    }
  }

  /// `cv2.adaptiveThreshold(..., GAUSSIAN_C, BINARY_INV, 11, 2)`: blur, round to
  /// uint8, then 255 where `src - mean <= -C`. The `<=` matches OpenCV's LUT.
  static Uint8List _adaptiveThresholdGaussianInv(
    Uint8List gray,
    int width,
    int height,
  ) {
    final mean = _gaussianBlurToUint8(gray, width, height, _blockSize);
    final out = Uint8List(gray.length);
    for (var i = 0; i < out.length; i++) {
      out[i] = (gray[i] - mean[i] <= -_thresholdC) ? 255 : 0;
    }
    return out;
  }

  /// Separable Gaussian matching `cv2.GaussianBlur(src32f, (k, k), 0)` with
  /// BORDER_REPLICATE. Sigma is OpenCV's default for sigma 0, 2.0 at k = 11.
  static Uint8List _gaussianBlurToUint8(
    Uint8List src,
    int width,
    int height,
    int kernelSize,
  ) {
    final kernel = _gaussianKernel(kernelSize);
    final radius = kernelSize >> 1;

    // Split into an edge region, where BORDER_REPLICATE has to clamp the sample
    // index, and an interior region where it cannot: keeping `clamp` out of the
    // inner loop roughly halves the per-frame cost.

    // Horizontal pass.
    final horizontal = Float32List(width * height);
    final xInteriorEnd = math.max(radius, width - radius);
    for (var y = 0; y < height; y++) {
      final row = y * width;
      for (var x = 0; x < math.min(radius, width); x++) {
        var acc = 0.0;
        for (var k = 0; k < kernelSize; k++) {
          acc += kernel[k] * src[row + (x + k - radius).clamp(0, width - 1)];
        }
        horizontal[row + x] = acc;
      }
      for (var x = radius; x < xInteriorEnd; x++) {
        final base = row + x - radius;
        var acc = 0.0;
        for (var k = 0; k < kernelSize; k++) {
          acc += kernel[k] * src[base + k];
        }
        horizontal[row + x] = acc;
      }
      for (var x = xInteriorEnd; x < width; x++) {
        var acc = 0.0;
        for (var k = 0; k < kernelSize; k++) {
          acc += kernel[k] * src[row + (x + k - radius).clamp(0, width - 1)];
        }
        horizontal[row + x] = acc;
      }
    }

    // Vertical pass, rounding to uint8 at the end (OpenCV's convertTo).
    final out = Uint8List(width * height);
    final yInteriorEnd = math.max(radius, height - radius);
    for (var y = 0; y < height; y++) {
      final row = y * width;
      if (y >= radius && y < yInteriorEnd) {
        for (var x = 0; x < width; x++) {
          var offset = (y - radius) * width + x;
          var acc = 0.0;
          for (var k = 0; k < kernelSize; k++) {
            acc += kernel[k] * horizontal[offset];
            offset += width;
          }
          out[row + x] = _saturateCastUint8(acc);
        }
      } else {
        for (var x = 0; x < width; x++) {
          var acc = 0.0;
          for (var k = 0; k < kernelSize; k++) {
            final sy = (y + k - radius).clamp(0, height - 1);
            acc += kernel[k] * horizontal[sy * width + x];
          }
          out[row + x] = _saturateCastUint8(acc);
        }
      }
    }
    return out;
  }

  /// `cv2.getGaussianKernel(kernelSize, 0)` — normalized to sum to 1.
  static Float32List _gaussianKernel(int kernelSize) {
    final sigma = 0.3 * ((kernelSize - 1) * 0.5 - 1) + 0.8;
    final scale = -0.5 / (sigma * sigma);
    final center = (kernelSize - 1) * 0.5;
    final kernel = Float32List(kernelSize);
    var sum = 0.0;
    for (var i = 0; i < kernelSize; i++) {
      final x = i - center;
      final value = math.exp(scale * x * x);
      kernel[i] = value;
      sum += value;
    }
    for (var i = 0; i < kernelSize; i++) {
      kernel[i] = kernel[i] / sum;
    }
    return kernel;
  }

  /// `cv2.boundingRect(cv2.findNonZero(binary))`, falling back to the whole
  /// image when nothing survived thresholding. Not squared off: step 5 stretches
  /// it to 96x96, which is what the model was trained on.
  static _Rect _foregroundBoundingBox(
    Uint8List binary,
    int width,
    int height,
  ) {
    var minX = width, minY = height, maxX = -1, maxY = -1;
    for (var y = 0; y < height; y++) {
      final row = y * width;
      for (var x = 0; x < width; x++) {
        if (binary[row + x] == 0) continue;
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
    }
    if (maxX < 0) return _Rect(0, 0, width, height);
    return _Rect(minX, minY, maxX - minX + 1, maxY - minY + 1);
  }

  /// `cv2.resize(..., INTER_AREA)` then `/ 255.0`.
  ///
  /// INTER_AREA is two algorithms: fractional-area averaging when both axes
  /// decimate, and the generic two-tap resampler as soon as one stretches. The
  /// foreground box is free-form, so both occur; treating the mixed case as an
  /// area average disagrees with OpenCV on 7940 of 9216 pixels.
  static Float32List _resizeAreaToUnit(
    Uint8List binary,
    int srcWidth,
    int srcHeight,
    _Rect box,
    int size,
  ) {
    // scale >= 1 means "this axis is being decimated".
    final decimatingBoth = box.width >= size && box.height >= size;
    return decimatingBoth
        ? _resizeDecimateToUnit(binary, srcWidth, box, size)
        : _resizeGenericToUnit(binary, srcWidth, box, size);
  }

  /// OpenCV's `resizeArea` path: fractional-area weights, accumulated in
  /// float, `saturate_cast<uchar>` at the end.
  static Float32List _resizeDecimateToUnit(
    Uint8List binary,
    int srcWidth,
    _Rect box,
    int size,
  ) {
    final xWeights = _areaWeights(box.width, size);
    final yWeights = _areaWeights(box.height, size);

    // Horizontal reduce: box.height rows of `size` columns.
    final horizontal = Float32List(box.height * size);
    for (var row = 0; row < box.height; row++) {
      final srcRow = (box.y + row) * srcWidth + box.x;
      final dstRow = row * size;
      for (var dx = 0; dx < size; dx++) {
        final weights = xWeights.weights[dx];
        final start = xWeights.starts[dx];
        var acc = 0.0;
        for (var k = 0; k < weights.length; k++) {
          acc += weights[k] * binary[srcRow + start + k];
        }
        horizontal[dstRow + dx] = acc;
      }
    }

    // Vertical reduce, normalizing to [0, 1] on the way out.
    final out = Float32List(size * size);
    for (var dy = 0; dy < size; dy++) {
      final weights = yWeights.weights[dy];
      final start = yWeights.starts[dy];
      final dstRow = dy * size;
      for (var dx = 0; dx < size; dx++) {
        var acc = 0.0;
        for (var k = 0; k < weights.length; k++) {
          acc += weights[k] * horizontal[(start + k) * size + dx];
        }
        // OpenCV rounds back to uint8 before the /255.
        out[dstRow + dx] = _saturateCastUint8(acc) / 255.0;
      }
    }
    return out;
  }

  /// OpenCV's generic 8-bit resampler, which `INTER_AREA` falls through to when
  /// an axis stretches. Fixed point, not float: coefficients quantized to
  /// `short` at `1 << 11`, int32 accumulation, descale by 22 bits with a
  /// half-step. In float ~3% of pixels land one level off.
  static Float32List _resizeGenericToUnit(
    Uint8List binary,
    int srcWidth,
    _Rect box,
    int size,
  ) {
    const coefBits = 11;
    const coefScale = 1 << coefBits;
    final xWeights = _generic2TapWeights(box.width, size);
    final yWeights = _generic2TapWeights(box.height, size);
    final xTaps = _quantizeWeights(xWeights, coefScale);
    final yTaps = _quantizeWeights(yWeights, coefScale);

    final horizontal = Int32List(box.height * size);
    for (var row = 0; row < box.height; row++) {
      final srcRow = (box.y + row) * srcWidth + box.x;
      final dstRow = row * size;
      for (var dx = 0; dx < size; dx++) {
        final taps = xTaps[dx];
        final start = xWeights.starts[dx];
        var acc = 0;
        for (var k = 0; k < taps.length; k++) {
          acc += taps[k] * binary[srcRow + start + k];
        }
        horizontal[dstRow + dx] = acc;
      }
    }

    const shift = coefBits * 2;
    const delta = 1 << (shift - 1);
    final out = Float32List(size * size);
    for (var dy = 0; dy < size; dy++) {
      final taps = yTaps[dy];
      final start = yWeights.starts[dy];
      final dstRow = dy * size;
      for (var dx = 0; dx < size; dx++) {
        var acc = 0;
        for (var k = 0; k < taps.length; k++) {
          acc += taps[k] * horizontal[(start + k) * size + dx];
        }
        final level = ((acc + delta) >> shift).clamp(0, 255);
        out[dstRow + dx] = level / 255.0;
      }
    }
    return out;
  }

  /// `saturate_cast<short>(weight * INTER_RESIZE_COEF_SCALE)` per tap.
  static List<Int32List> _quantizeWeights(_AxisWeights weights, int scale) {
    return weights.weights.map((taps) {
      final quantized = Int32List(taps.length);
      for (var k = 0; k < taps.length; k++) {
        quantized[k] = _roundHalfEven(taps[k] * scale);
      }
      return quantized;
    }).toList(growable: false);
  }

  /// Source ranges and weights per destination index for an area resize.
  /// Weights are renormalized to 1, covering the clipped last pixel too.
  static _AxisWeights _areaWeights(int srcLength, int dstLength) {
    final scale = srcLength / dstLength;
    final starts = Int32List(dstLength);
    final weights = <Float32List>[];
    for (var d = 0; d < dstLength; d++) {
      final s0 = d * scale;
      final s1 = (d + 1) * scale;
      var first = s0.floor();
      if (first > srcLength - 1) first = srcLength - 1;
      var last = s1.ceil();
      if (last > srcLength) last = srcLength;
      final count = math.max(1, last - first);

      final w = Float32List(count);
      var total = 0.0;
      for (var i = 0; i < count; i++) {
        final lo = math.max(s0, (first + i).toDouble());
        final hi = math.min(s1, (first + i + 1).toDouble());
        final overlap = hi - lo;
        w[i] = overlap > 0 ? overlap : 0.0;
        total += w[i];
      }
      if (total <= 0) {
        w[0] = 1.0;
        total = 1.0;
      }
      for (var i = 0; i < count; i++) {
        w[i] = w[i] / total;
      }

      starts[d] = first;
      weights.add(w);
    }
    return _AxisWeights(starts, weights);
  }

  /// Coefficients from `cv::resize`'s `area_mode` branch:
  ///
  /// ```cpp
  /// sx = cvFloor(dx * scale);
  /// fx = (float)((dx + 1) - (sx + 1) * inv_scale);
  /// fx = fx <= 0 ? 0.f : fx - cvFloor(fx);
  /// if (sx >= src_len - 1) { fx = 0; sx = src_len - 1; }
  /// ```
  ///
  /// Agrees with [_areaWeights] on an upscaling axis, diverges on a decimating one.
  static _AxisWeights _generic2TapWeights(int srcLength, int dstLength) {
    final scale = srcLength / dstLength;
    final invScale = dstLength / srcLength;
    final starts = Int32List(dstLength);
    final weights = <Float32List>[];
    for (var d = 0; d < dstLength; d++) {
      var sx = (d * scale).floor();
      var fx = (d + 1) - (sx + 1) * invScale;
      fx = fx <= 0 ? 0.0 : fx - fx.floor();
      if (sx < 0) {
        fx = 0.0;
        sx = 0;
      }
      if (sx >= srcLength - 1) {
        fx = 0.0;
        sx = srcLength - 1;
      }

      starts[d] = sx;
      weights.add(
        sx >= srcLength - 1
            ? Float32List.fromList(<double>[1.0])
            : Float32List.fromList(<double>[1.0 - fx, fx]),
      );
    }
    return _AxisWeights(starts, weights);
  }

  // Stages exposed so the tests can pin each against its `cv2` counterpart.

  @visibleForTesting
  static Uint8List debugGrayscale(img.Image source) => _toGrayscale(source);

  @visibleForTesting
  static void debugEqualizeHist(Uint8List gray) => _equalizeHistInPlace(gray);

  @visibleForTesting
  static Uint8List debugAdaptiveThreshold(
    Uint8List gray,
    int width,
    int height,
  ) =>
      _adaptiveThresholdGaussianInv(gray, width, height);

  /// OpenCV's `saturate_cast<uchar>(float)`: round half to even, then clamp.
  static int _saturateCastUint8(double value) {
    if (value <= 0) return 0;
    if (value >= 255) return 255;
    return _roundHalfEven(value);
  }

  /// `cvRound` -- round half to even, unlike Dart's `round()`.
  static int _roundHalfEven(double value) {
    final floor = value.floor();
    final fraction = value - floor;
    if (fraction > 0.5) return floor + 1;
    if (fraction < 0.5) return floor;
    return floor.isEven ? floor : floor + 1;
  }
}

class _Rect {
  const _Rect(this.x, this.y, this.width, this.height);
  final int x;
  final int y;
  final int width;
  final int height;
}

class _AxisWeights {
  const _AxisWeights(this.starts, this.weights);
  final Int32List starts;
  final List<Float32List> weights;
}
