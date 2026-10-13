import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:nsl_fyp/services/offline_model/nsl_preprocessor.dart';

/// Numerically pins [NslPreprocessor] to real OpenCV output.
///
/// The fixtures under `test/fixtures/` came from cv2 4.10 running the chain in
/// `lib/dart preprocessing implementation guide.txt`: `<case>_expected.bin` is
/// the final 96x96 uint8 image (the Dart tensor divided by 255), and
/// `_gray`/`_eq`/`_binary` are the intermediates, for localising a failure to
/// one stage.
///
/// The cases cover every resize branch, since `INTER_AREA` dispatches on the
/// crop's aspect ratio: both axes decimating (blob/big, the normal camera case),
/// both upscaling (noise/tiny), and the mixed directions (wide/tall) that go
/// through OpenCV's generic two-tap resampler.
void main() {
  final fixtures = Directory('test/fixtures');
  final manifest =
      (jsonDecode(File('${fixtures.path}/manifest.json').readAsStringSync())
              as List)
          .cast<Map<String, dynamic>>();

  img.Image sourceFor(String name) => img.decodePng(
        File('${fixtures.path}/$name.png').readAsBytesSync(),
      )!;

  Uint8List fixtureBytes(String name, String stage) =>
      File('${fixtures.path}/${name}_$stage.bin').readAsBytesSync();

  group('end-to-end tensor matches cv2', () {
    for (final entry in manifest) {
      final name = entry['name'] as String;
      final grayscaleSource = entry['grayscaleSource'] as bool;

      test(name, () {
        final source = sourceFor(name);
        expect(source.width, entry['width'] as int);
        expect(source.height, entry['height'] as int);

        final actual = NslPreprocessor.preprocess(source);
        final expected = fixtureBytes(name, 'expected');

        expect(
          actual.length,
          NslPreprocessor.inputSize * NslPreprocessor.inputSize,
        );
        expect(expected.length, actual.length);
        for (final value in actual) {
          expect(value, inInclusiveRange(0.0, 1.0));
        }

        var mismatches = 0;
        var maxDelta = 0;
        for (var i = 0; i < actual.length; i++) {
          final delta = ((actual[i] * 255.0).round() - expected[i]).abs();
          if (delta != 0) {
            mismatches++;
            if (delta > maxDelta) maxDelta = delta;
          }
        }

        final detail =
            '$mismatches/${actual.length} pixels differ, max delta $maxDelta';
        if (grayscaleSource) {
          // Every stage up to the resize matches cv2 bit for bit (see the
          // per-stage test). What is left is one level on some antialiased edge
          // pixels, from accumulation precision in the resize: OpenCV sums in
          // float32, this port in doubles rounded once at the end. A delta above
          // 1, or a large share of pixels, would mean a wrong branch or weights.
          expect(maxDelta, lessThanOrEqualTo(1), reason: detail);
          expect(mismatches / actual.length, lessThan(0.05), reason: detail);
        } else {
          // A colour source inherits cv2's +/-1 cvtColor difference, and one
          // flipped grayscale level can flip a pixel across the adaptive
          // threshold -- so bound the *count*, not the size.
          expect(mismatches / actual.length, lessThan(0.02), reason: detail);
        }
      });
    }
  });

  group('per-stage output matches cv2', () {
    for (final entry in manifest) {
      final name = entry['name'] as String;
      final grayscaleSource = entry['grayscaleSource'] as bool;

      test(name, () {
        final source = sourceFor(name);

        // --- 1. cv2.cvtColor(..., COLOR_BGR2GRAY) ---
        final gray = NslPreprocessor.debugGrayscale(source);
        final expectedGray = fixtureBytes(name, 'gray');
        if (grayscaleSource) {
          expect(_maxDelta(gray, expectedGray), 0,
              reason: 'COLOR_BGR2GRAY mismatch on an r==g==b source');
        } else {
          // `_toGrayscale` implements OpenCV's reference integer formula,
          // CV_DESCALE(r*4899 + g*9617 + b*1868, 14). cv2 4.10's vectorised path
          // lands one level away on ~0.3% of pixels and no integer coefficient
          // triple reproduces it (brute-forced +/-6, IPP disabled) -- a
          // difference between OpenCV builds rather than a port error, so pin
          // both the size and the frequency.
          expect(_maxDelta(gray, expectedGray), lessThanOrEqualTo(1),
              reason: 'COLOR_BGR2GRAY mismatch');
          expect(_differingFraction(gray, expectedGray), lessThan(0.01),
              reason: 'COLOR_BGR2GRAY differs on too many pixels');
        }

        // --- 2. cv2.equalizeHist ---
        // Fed cv2's own grayscale so this assertion is exact instead of
        // inheriting the difference above.
        final equalized = Uint8List.fromList(expectedGray);
        NslPreprocessor.debugEqualizeHist(equalized);
        expect(_maxDelta(equalized, fixtureBytes(name, 'eq')), 0,
            reason: 'equalizeHist mismatch');

        // --- 3. cv2.adaptiveThreshold(GAUSSIAN_C, BINARY_INV, 11, 2) ---
        final binary = NslPreprocessor.debugAdaptiveThreshold(
          equalized,
          source.width,
          source.height,
        );
        expect(_maxDelta(binary, fixtureBytes(name, 'binary')), 0,
            reason: 'adaptiveThreshold mismatch');
      });
    }
  });

  test('all-uniform input degrades gracefully', () {
    final flat = img.Image(width: 50, height: 40, numChannels: 3);
    img.fill(flat, color: img.ColorRgb8(30, 30, 30));
    final tensor = NslPreprocessor.preprocess(flat);
    expect(
      tensor.length,
      NslPreprocessor.inputSize * NslPreprocessor.inputSize,
    );
    // Nothing survives thresholding a flat image, so the bounding-box step
    // must fall back to the full frame instead of crashing on an empty rect.
    expect(tensor.every((v) => v == 0.0), isTrue);
  });

  test('tensor is a plain float32 buffer of the model input size', () {
    final tensor = NslPreprocessor.preprocess(sourceFor('blob_640x480'));
    expect(tensor, isA<Float32List>());
    // 96 * 96 * 1 channel * 4 bytes — what the [1, 96, 96, 1] float32 input
    // tensor expects, with no channel tiling on the Dart side.
    expect(tensor.lengthInBytes, 96 * 96 * 4);
  });
}

int _maxDelta(List<int> a, List<int> b) {
  expect(a.length, b.length);
  var max = 0;
  for (var i = 0; i < a.length; i++) {
    final d = (a[i] - b[i]).abs();
    if (d > max) max = d;
  }
  return max;
}

double _differingFraction(List<int> a, List<int> b) {
  expect(a.length, b.length);
  var differing = 0;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) differing++;
  }
  return differing / a.length;
}
