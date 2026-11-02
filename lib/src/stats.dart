import 'dart:math' as math;

import 'results.dart';

/// The result of a two-sided Mann-Whitney U test between two samples.
final class MannWhitneyResult {
  /// Pairs (a, b) with a > b, plus half the tied pairs. Ranges from 0 to
  /// `a.length * b.length`.
  final double uA;

  /// Two-sided p-value.
  final double pValue;

  /// True if [pValue] is from the exact distribution, false if it is from
  /// the normal approximation.
  final bool exact;

  const MannWhitneyResult({
    required this.uA,
    required this.pValue,
    required this.exact,
  });
}

/// The largest combined sample count for the exact distribution. Above
/// this, the counts do not fit exactly in a double.
const _maxExactTotal = 50;

/// Two-sided Mann-Whitney U test of [a] against [b].
///
/// Uses the exact distribution if there are no ties and the combined size
/// is at most 50. Otherwise uses the normal approximation with tie and
/// continuity corrections.
///
/// Throws an [ArgumentError] if either sample is empty.
MannWhitneyResult mannWhitneyU(List<double> a, List<double> b) {
  if (a.isEmpty) throw ArgumentError.value(a, 'a', 'Must not be empty');
  if (b.isEmpty) throw ArgumentError.value(b, 'b', 'Must not be empty');
  final n1 = a.length;
  final n2 = b.length;
  final n = n1 + n2;

  // Rank the combined samples; tied values get the average rank.
  final combined = [for (final x in a) (x, true), for (final x in b) (x, false)]
    ..sort((p, q) => p.$1.compareTo(q.$1));
  var rankSumA = 0.0;
  var tieTerm = 0.0; // Sum of t^3 - t over tie groups.
  for (var i = 0; i < n;) {
    var j = i + 1;
    while (j < n && combined[j].$1 == combined[i].$1) {
      j++;
    }
    final t = j - i;
    final averageRank = (i + 1 + j) / 2; // Ranks i+1 .. j.
    for (var k = i; k < j; k++) {
      if (combined[k].$2) rankSumA += averageRank;
    }
    tieTerm += t * t * t - t;
    i = j;
  }
  final uA = rankSumA - n1 * (n1 + 1) / 2;
  final mean = n1 * n2 / 2;

  if (tieTerm == 0 && n <= _maxExactTotal) {
    final counts = _uDistribution(n1, n2);
    final total = counts.fold(0.0, (sum, c) => sum + c);
    // With no ties, uA is a whole number.
    final u = uA.round();
    var lower = 0.0;
    for (var k = 0; k <= u; k++) {
      lower += counts[k];
    }
    var upper = 0.0;
    for (var k = u; k < counts.length; k++) {
      upper += counts[k];
    }
    final p = math.min(1.0, 2 * math.min(lower, upper) / total);
    return MannWhitneyResult(uA: uA, pValue: p, exact: true);
  }

  final variance = n1 * n2 / 12 * ((n + 1) - tieTerm / (n * (n - 1)));
  if (variance <= 0) {
    // Every value is the same.
    return MannWhitneyResult(uA: uA, pValue: 1, exact: false);
  }
  final z = math.max(0.0, (uA - mean).abs() - 0.5) / math.sqrt(variance);
  return MannWhitneyResult(
    uA: uA,
    pValue: math.min(1.0, _erfc(z / math.sqrt2)),
    exact: false,
  );
}

/// The number of orderings of [n1] and [n2] untied values that give each
/// U, from 0 to n1 * n2.
///
/// These are the coefficients of the Gaussian binomial coefficient
/// [n1 + n2 choose n1] in q. Each step keeps whole-number coefficients no
/// larger than C(n1 + n2, n1), so doubles hold them exactly when
/// n1 + n2 <= 50.
List<double> _uDistribution(int n1, int n2) {
  final size = n1 * n2 + 1;
  final poly = List<double>.filled(size, 0)..[0] = 1;
  var degree = 0;
  for (var i = 1; i <= n1; i++) {
    // Multiply by (1 - q^(n2 + i)), then divide by (1 - q^i). The product
    // has degree `degree + n2 + i`; dividing it exactly sets the terms
    // above `degree + n2` back to zero.
    final shift = n2 + i;
    final top = math.min(degree + shift, size - 1);
    for (var k = top; k >= shift; k--) {
      poly[k] -= poly[k - shift];
    }
    for (var k = i; k <= top; k++) {
      poly[k] += poly[k - i];
    }
    degree += n2;
  }
  return poly;
}

/// Complementary error function. Fractional error below 1.2e-7.
///
/// From Numerical Recipes, section 6.2 (erfcc).
double _erfc(double x) {
  final z = x.abs();
  final t = 1 / (1 + 0.5 * z);
  final r =
      t *
      math.exp(
        -z * z -
            1.26551223 +
            t *
                (1.00002368 +
                    t *
                        (0.37409196 +
                            t *
                                (0.09678418 +
                                    t *
                                        (-0.18628806 +
                                            t *
                                                (0.27886807 +
                                                    t *
                                                        (-1.13520398 +
                                                            t *
                                                                (1.48851587 +
                                                                    t *
                                                                        (-0.82215223 +
                                                                            t * 0.17087277)))))))),
      );
  return x >= 0 ? r : 2 - r;
}

/// The smallest two-sided p-value possible for samples of size [n1] and
/// [n2]: all of one sample is below all of the other.
double minimumPValue(int n1, int n2) {
  // 2 / C(n1 + n2, n1), computed in a way that does not overflow.
  var logChoose = 0.0;
  for (var i = 1; i <= n1; i++) {
    logChoose += math.log(n2 + i) - math.log(i);
  }
  return math.min(1.0, 2 * math.exp(-logChoose));
}

/// Compares [candidate] to [baseline] with a two-sided Mann-Whitney U test
/// on their samples.
Comparison compare(
  ImplResult baseline,
  ImplResult candidate, {
  double significanceLevel = 0.05,
}) {
  final n1 = baseline.samples.length;
  final n2 = candidate.samples.length;
  final speedup = baseline.median / candidate.median;

  if (minimumPValue(n1, n2) > significanceLevel) {
    return Comparison(
      baselineName: baseline.name,
      implementationName: candidate.name,
      speedup: speedup,
      probabilityFaster: double.nan,
      pValue: double.nan,
      significanceLevel: significanceLevel,
      verdict: ComparisonVerdict.tooFewSamples,
    );
  }

  final test = mannWhitneyU(baseline.samples, candidate.samples);
  // uA counts pairs where the baseline sample is slower (larger).
  final probabilityFaster = test.uA / (n1 * n2);
  final ComparisonVerdict verdict;
  if (test.pValue >= significanceLevel) {
    verdict = ComparisonVerdict.noSignificantDifference;
  } else if (probabilityFaster > 0.5) {
    verdict = ComparisonVerdict.faster;
  } else {
    verdict = ComparisonVerdict.slower;
  }
  return Comparison(
    baselineName: baseline.name,
    implementationName: candidate.name,
    speedup: speedup,
    probabilityFaster: probabilityFaster,
    pValue: test.pValue,
    significanceLevel: significanceLevel,
    verdict: verdict,
  );
}

/// The fewest samples per implementation that can give a significant result
/// at [significanceLevel].
int minimumSamplesFor(double significanceLevel) {
  var n = 1;
  while (minimumPValue(n, n) > significanceLevel) {
    n++;
  }
  return n;
}
