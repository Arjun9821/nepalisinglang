import 'dart:math' as math;
import 'dart:typed_data';

/// Landmark -> feature-vector transform for the NSL landmark classifier.
///
/// A port of the Python `feats()` used in training, which fixes the model's
/// input layout, so **the arithmetic and ordering must not change**:
///
/// | Range | Content                                               |
/// |-------|-------------------------------------------------------|
/// | 0-62  | 21 landmarks x (x, y, z), in landmark index order      |
/// | 63-72 | Fingertip pair distances, loop order i=0..4, j=i+1..4  |
/// | 73-77 | Curl angles, in [_curls] order                         |
///
/// Reordering produces confident nonsense rather than an error, since the model
/// consumes any 78 floats. `parity.dart` is the defence against that.
class Features {
  Features._();

  static const int dim = 78;

  /// Landmark indices of the five fingertips.
  static const _tips = [4, 8, 12, 16, 20];

  /// (a, b, c) triples whose two segments give a finger's curl angle.
  static const _curls = [
    [1, 2, 3],
    [5, 6, 7],
    [9, 10, 11],
    [13, 14, 15],
    [17, 18, 19],
  ];

  /// 21 landmarks as `[x, y, z]` -> 78 raw features, or null for a degenerate
  /// hand (zero scale) or a wrong-sized input, which the caller must treat as
  /// no prediction for this frame rather than substituting a default.
  static Float32List? compute(List<List<double>> raw) {
    if (raw.length != 21) return null;
    final lm = [for (final p in raw) List<double>.from(p)];

    // Translate the wrist to the origin.
    final w = List<double>.from(lm[0]);
    for (final p in lm) {
      p[0] -= w[0];
      p[1] -= w[1];
      p[2] -= w[2];
    }

    // Scale by the wrist -> middle-MCP distance. lm[0] is the origin after the
    // translation, so norm(lm[9] - lm[0]) reduces to norm(lm[9]).
    final s = math.sqrt(
        lm[9][0] * lm[9][0] + lm[9][1] * lm[9][1] + lm[9][2] * lm[9][2]);
    if (s < 1e-6) return null;
    for (final p in lm) {
      p[0] /= s;
      p[1] /= s;
      p[2] /= s;
    }

    final out = Float32List(dim);
    var k = 0;

    // 0-62: the normalised landmarks, flattened.
    for (final p in lm) {
      out[k++] = p[0];
      out[k++] = p[1];
      out[k++] = p[2];
    }

    // 63-72: pairwise fingertip distances.
    for (var i = 0; i < 5; i++) {
      for (var j = i + 1; j < 5; j++) {
        final a = lm[_tips[i]], b = lm[_tips[j]];
        final dx = a[0] - b[0], dy = a[1] - b[1], dz = a[2] - b[2];
        out[k++] = math.sqrt(dx * dx + dy * dy + dz * dz);
      }
    }

    // 73-77: curl angles.
    for (final c in _curls) {
      final a = lm[c[0]], b = lm[c[1]], d = lm[c[2]];
      final v1 = [b[0] - a[0], b[1] - a[1], b[2] - a[2]];
      final v2 = [d[0] - b[0], d[1] - b[1], d[2] - b[2]];
      final dot = v1[0] * v2[0] + v1[1] * v2[1] + v1[2] * v2[2];
      final n1 = math.sqrt(v1[0] * v1[0] + v1[1] * v1[1] + v1[2] * v1[2]);
      final n2 = math.sqrt(v2[0] * v2[0] + v2[1] * v2[1] + v2[2] * v2[2]);
      // The 1e-8 guard matches the Python exactly.
      out[k++] = math.acos((dot / (n1 * n2 + 1e-8)).clamp(-1.0, 1.0));
    }

    return out;
  }

  /// Applies the training-time standardisation `(f - mu) / sd`. [mu] and [sd]
  /// come from `meta.json`: a mismatched pair predicts the wrong class
  /// confidently.
  static Float32List standardise(
      Float32List f, List<double> mu, List<double> sd) {
    final o = Float32List(f.length);
    for (var i = 0; i < f.length; i++) {
      o[i] = (f[i] - mu[i]) / sd[i];
    }
    return o;
  }
}
