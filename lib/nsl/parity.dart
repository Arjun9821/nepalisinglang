import 'dart:convert';

import 'package:flutter/services.dart';

import 'features.dart';
import 'model.dart';

/// Outcome of the section 6 parity gate.
class ParityResult {
  final double featDiff, logitDiff;
  final int agree, total;

  /// Rows in `parity.json` left unexercised because the fixture's arrays
  /// disagree in length. Non-zero forces [pass] false.
  final int untested;

  ParityResult(this.featDiff, this.logitDiff, this.agree, this.total,
      {this.untested = 0});

  bool get pass =>
      untested == 0 &&
      total > 0 &&
      featDiff < 1e-3 &&
      logitDiff < 1e-2 &&
      agree == total;

  @override
  String toString() {
    final base = 'featDiff=${featDiff.toStringAsExponential(2)} '
        'logitDiff=${logitDiff.toStringAsExponential(2)} '
        'agree=$agree/$total';
    final warn = untested > 0 ? ' UNTESTED=$untested' : '';
    return '$base$warn ${pass ? "PASS" : "FAIL"}';
  }
}

/// Thrown when `parity.json` cannot support a meaningful gate.
class ParityFixtureError extends StateError {
  ParityFixtureError(super.message);
}

/// Runs the two-stage parity check from section 6: [Features.compute] against
/// the fixture's stored features, then standardisation + interpreter output
/// against the stored logits, requiring exact argmax agreement.
///
/// The lengths are checked up front. The spec's skeleton looped over
/// `landmarks.length` and derived `agree == total` from it, so a fixture with
/// fewer landmark rows than feature rows -- as the shipped one had, 12 against
/// 30 -- reports a confident PASS while skipping the remainder.
Future<ParityResult> runParity(NslModel model) async {
  final p = jsonDecode(await rootBundle.loadString('assets/parity.json'))
      as Map<String, dynamic>;
  final lms = p['landmarks'] as List;
  final feats = p['feats'] as List;
  final logits = p['logits'] as List;

  if (lms.isEmpty) {
    throw ParityFixtureError('parity.json contains no landmark rows.');
  }
  if (lms.length != feats.length || lms.length != logits.length) {
    throw ParityFixtureError(
      'parity.json is ragged: landmarks=${lms.length}, feats=${feats.length}, '
      'logits=${logits.length}. All three must have the same length and be '
      'row-aligned, otherwise the gate silently tests only the first '
      '${lms.length} rows and still reports PASS. Regenerate the fixture so '
      'that landmarks[i], feats[i] and logits[i] all describe the same sample.',
    );
  }

  double fd = 0, ld = 0;
  var agree = 0;

  for (var i = 0; i < lms.length; i++) {
    // Stage 1 -- tests Features.compute()
    final raw = (lms[i] as List)
        .map<List<double>>(
            (r) => (r as List).map((e) => (e as num).toDouble()).toList())
        .toList();
    final got = Features.compute(raw);
    if (got == null) {
      throw ParityFixtureError('compute() returned null at row $i');
    }
    final exp =
        (feats[i] as List).map((e) => (e as num).toDouble()).toList();
    for (var j = 0; j < got.length; j++) {
      final d = (got[j] - exp[j]).abs();
      if (d > fd) fd = d;
    }

    // Stage 2 -- tests standardisation + the interpreter
    final gl = model.infer(Features.standardise(got, model.mu, model.sd));
    final el =
        (logits[i] as List).map((e) => (e as num).toDouble()).toList();
    for (var j = 0; j < gl.length; j++) {
      final d = (gl[j] - el[j]).abs();
      if (d > ld) ld = d;
    }
    if (_argmax(gl) == _argmax(el)) agree++;
  }

  return ParityResult(fd, ld, agree, lms.length);
}

int _argmax(List<double> v) {
  var b = 0;
  for (var i = 1; i < v.length; i++) {
    if (v[i] > v[b]) b = i;
  }
  return b;
}
