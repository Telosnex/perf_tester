import 'dart:math' as math;

import 'package:perf_tester/perf_tester.dart';
import 'package:test/test.dart';

/// Two-sided p-value by listing every way to split the ranks 1..n1+n2.
double bruteForceP(int n1, int n2, double observedU) {
  final n = n1 + n2;
  final us = <double>[];
  void choose(int start, int left, int rankSum) {
    if (left == 0) {
      us.add(rankSum - n1 * (n1 + 1) / 2);
      return;
    }
    for (var rank = start; rank <= n - left + 1; rank++) {
      choose(rank + 1, left - 1, rankSum + rank);
    }
  }

  choose(1, n1, 0);
  final lower = us.where((u) => u <= observedU).length;
  final upper = us.where((u) => u >= observedU).length;
  return math.min(1.0, 2 * math.min(lower, upper) / us.length);
}

ImplResult impl(String name, List<double> samples) =>
    ImplResult(name: name, samples: samples, casesPerSample: 1);

void main() {
  group('mannWhitneyU', () {
    test('exact p-value matches brute force without ties', () {
      final random = math.Random(1);
      for (var trial = 0; trial < 200; trial++) {
        final n1 = 1 + random.nextInt(8);
        final n2 = 1 + random.nextInt(8);
        final shift = (trial % 3) * 0.3;
        final a = List.generate(n1, (_) => random.nextDouble() + shift);
        final b = List.generate(n2, (_) => random.nextDouble());
        final result = mannWhitneyU(a, b);
        expect(result.exact, isTrue);
        expect(
          result.pValue,
          closeTo(bruteForceP(n1, n2, result.uA), 1e-12),
          reason: 'a=$a b=$b',
        );
      }
    });

    test('U counts pairs where a is larger, ties as half', () {
      final result = mannWhitneyU([1, 2, 3], [2, 2, 0]);
      // 1: >0 → 1. 2: >0, ties 2 → 1 + 1. 3: > all → 3.
      expect(result.uA, 1 + 2 + 3);
    });

    test('ties use the normal approximation with tie correction', () {
      // Same data and formula computed independently in Python.
      final result = mannWhitneyU(
        [1, 2, 2, 3, 5, 8, 8, 8, 9, 12, 13, 20],
        [2, 4, 4, 6, 7, 7, 10, 11, 15, 16, 18, 21, 22],
      );
      expect(result.exact, isFalse);
      expect(result.uA, 56);
      expect(result.pValue, closeTo(0.241317, 1e-6));
    });

    test('large samples use the normal approximation', () {
      final a = List.generate(40, (i) => i + 0.5);
      final b = List.generate(40, (i) => i + 0.25);
      final result = mannWhitneyU(a, b);
      expect(result.exact, isFalse);
      expect(result.pValue, greaterThan(0.5));
    });

    test('identical values give p = 1', () {
      expect(mannWhitneyU([1, 1, 1, 1, 1], [1, 1, 1, 1, 1]).pValue, 1);
    });

    test('exact and approximate p-values agree near the switch', () {
      final a = List.generate(25, (i) => i + 0.5);
      final b = List.generate(25, (i) => i + 3.2);
      final exact = mannWhitneyU(a, b);
      final approx = mannWhitneyU([...a, 100], [...b, 100.5]);
      expect(exact.exact, isTrue);
      expect(approx.exact, isFalse);
      expect(approx.pValue, closeTo(exact.pValue, 0.03));
    });

    test('empty samples throw', () {
      expect(() => mannWhitneyU([], [1]), throwsArgumentError);
      expect(() => mannWhitneyU([1], []), throwsArgumentError);
    });
  });

  test('minimumPValue and minimumSamplesFor', () {
    expect(minimumPValue(4, 4), closeTo(2 / 70, 1e-15));
    expect(minimumPValue(1, 1), 1);
    expect(minimumPValue(100, 100), lessThan(1e-50));
    expect(minimumSamplesFor(0.05), 4);
    expect(minimumSamplesFor(0.01), 5);
  });

  group('compare', () {
    test('separated samples are significant in the right direction', () {
      final base = impl('Base', [10, 11, 12, 13, 14]);
      final fast = impl('Fast', [5, 6, 7, 8, 9]);
      final faster = compare(base, fast);
      expect(faster.verdict, ComparisonVerdict.faster);
      expect(faster.speedup, 12 / 7);
      expect(faster.probabilityFaster, 1);
      expect(faster.pValue, closeTo(2 / 252, 1e-12));

      final slower = compare(fast, base);
      expect(slower.verdict, ComparisonVerdict.slower);
      expect(slower.probabilityFaster, 0);
    });

    test('overlapping samples are not significant', () {
      final c = compare(
        impl('A', [10, 12, 14, 16, 18]),
        impl('B', [11, 13, 15, 17, 19]),
      );
      expect(c.verdict, ComparisonVerdict.noSignificantDifference);
      expect(c.isSignificant, isFalse);
      expect(c.speedup, closeTo(14 / 15, 1e-12));
    });

    test('a different median alone is not significant', () {
      // One outlier moves the mean, not the ranks.
      final c = compare(
        impl('A', [10, 11, 12, 13, 14, 15]),
        impl('B', [10.5, 11.5, 12.5, 13.5, 14.5, 100]),
      );
      expect(c.verdict, ComparisonVerdict.noSignificantDifference);
    });

    test('significance level controls the verdict', () {
      final a = impl('A', [1, 2, 3, 4, 5, 6]);
      final b = impl('B', [2.5, 3.5, 4.5, 5.5, 6.5, 7.5]);
      final p = compare(a, b).pValue;
      expect(compare(a, b, significanceLevel: p * 0.99).isSignificant, isFalse);
      expect(compare(a, b, significanceLevel: p * 1.01).isSignificant, isTrue);
    });

    test('too few samples', () {
      final c = compare(impl('A', [1, 2, 3]), impl('B', [10, 20, 30]));
      expect(c.verdict, ComparisonVerdict.tooFewSamples);
      expect(c.probabilityFaster, isNaN);
      expect(c.pValue, isNaN);
      expect(c.speedup, 2 / 20);
    });
  });
}
