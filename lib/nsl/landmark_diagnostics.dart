import 'dart:math' as math;

/// Geometry of one frame's raw landmarks, before [Features.compute] runs.
///
/// The parity gate injects stored landmarks, so nothing upstream of
/// `Features.compute` is validated and a build can pass 36/36 while predicting
/// badly live. The hazard: `Features.compute` is scale invariant but not aspect
/// invariant, since MediaPipe normalises x by width and y by height
/// independently, so a different frame aspect ratio shifts every feature with no
/// error anywhere. Comparing against [LandmarkReference] separates that from
/// MediaPipe version drift, which needs a retrain instead.
class LandmarkGeometry {
  LandmarkGeometry({
    required this.xSpread,
    required this.ySpread,
    required this.wristToMcpDx,
    required this.wristToMcpDy,
    required this.zRange,
  });

  /// Width of the landmark cloud in normalised units.
  final double xSpread;

  /// Height of the landmark cloud in normalised units.
  final double ySpread;

  /// Wrist (0) -> middle-finger MCP (9) vector; its direction is how a rotation
  /// mismatch shows up.
  final double wristToMcpDx, wristToMcpDy;

  /// Spread of the z channel, as a sanity check that depth is populated at all.
  final double zRange;

  /// Ratio of horizontal to vertical extent -- the aspect-sensitive number,
  /// which should stay near [LandmarkReference.spreadRatio] at any hand size.
  double get spreadRatio => ySpread == 0 ? 0 : xSpread / ySpread;

  /// Direction the fingers point, in degrees, measured from straight up.
  /// 0 = fingers up, +/-90 = sideways, 180 = fingers down.
  double get pointingAngleDeg =>
      math.atan2(wristToMcpDx, -wristToMcpDy) * 180 / math.pi;

  static LandmarkGeometry? of(List<List<double>>? lm) {
    if (lm == null || lm.length != 21) return null;
    var minX = double.infinity, maxX = -double.infinity;
    var minY = double.infinity, maxY = -double.infinity;
    var minZ = double.infinity, maxZ = -double.infinity;
    for (final p in lm) {
      minX = math.min(minX, p[0]);
      maxX = math.max(maxX, p[0]);
      minY = math.min(minY, p[1]);
      maxY = math.max(maxY, p[1]);
      minZ = math.min(minZ, p[2]);
      maxZ = math.max(maxZ, p[2]);
    }
    return LandmarkGeometry(
      xSpread: maxX - minX,
      ySpread: maxY - minY,
      wristToMcpDx: lm[9][0] - lm[0][0],
      wristToMcpDy: lm[9][1] - lm[0][1],
      zRange: maxZ - minZ,
    );
  }
}

/// What the training data looked like, measured from the 36 rows in
/// `assets/parity.json`. Descriptive, not thresholds -- but live geometry far
/// from these means the camera path delivers a differently-shaped hand than the
/// model was trained on.
class LandmarkReference {
  LandmarkReference._();

  /// Mean per-sample x extent across the 36 fixture rows.
  static const double xSpread = 0.489;

  /// Mean per-sample y extent across the 36 fixture rows.
  static const double ySpread = 0.328;

  /// x/y extent ratio. Greater than 1 despite the fingers pointing up, which is
  /// the signature of portrait-shaped source images.
  static const double spreadRatio = xSpread / ySpread; // ~1.49

  /// Mean wrist -> middle-MCP direction: essentially straight up the frame.
  static const double pointingAngleDeg = -6.2;

  /// Mean wrist -> middle-MCP vector. Negative dy with near-zero dx = fingers
  /// up; a swapped or sign-flipped pair names a rotation.
  static const double wristToMcpDx = -0.019;
  static const double wristToMcpDy = -0.172;

  /// How far a live ratio may drift before it is worth investigating: loose
  /// enough for hand variation, tight enough to catch a 90-degree rotation.
  static const double ratioTolerance = 0.45;

  static bool ratioLooksWrong(double liveRatio) =>
      (liveRatio - spreadRatio).abs() > ratioTolerance;
}
