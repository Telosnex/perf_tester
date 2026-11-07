import 'dart:async';
import 'package:perf_tester/perf_tester.dart';
import 'package:test/test.dart';

Future<List<String>> captureOutput(Future<void> Function() body) async {
  final lines = <String>[];
  await runZoned(
    body,
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) => lines.add(line),
    ),
  );
  return lines;
}

void main() {
  validationAndStateTests();

  test('two implementations verify and produce requested samples', () async {
    var calls = 0;
    final tester = PerfTester<int, int>(
      testName: 'comparison',
      testCases: [1, 2, 3],
      implementation1: (n) {
        calls++;
        return n * 2;
      },
      implementation2: (n) async => n + n,
    );
    final lines = await captureOutput(
      () => tester.run(
        warmupRuns: 2,
        benchmarkRuns: 3,
        minSampleTime: Duration.zero,
      ),
    );
    expect(calls, 3 + 2 + 9);
    expect(tester.impl1Times, hasLength(3));
    expect(tester.impl2Times, hasLength(3));
    expect(
      tester.implTimes.expand((times) => times),
      everyElement(isNonNegative),
    );
    expect(lines.join('\n'), contains('All 3 test cases match'));
  });

  test('custom equality supports non-JSON outputs', () async {
    var comparisons = 0;
    final tester = PerfTester<int, Set<int>>(
      testName: 'sets',
      testCases: [1, 2],
      implementation1: (n) => {n, 0},
      implementation2: (n) => {0, n},
      equalityCheck: (a, b) {
        comparisons++;
        return a!.length == b!.length && a.containsAll(b);
      },
    );
    final lines = await captureOutput(
      () => tester.run(warmupRuns: 0, benchmarkRuns: 2),
    );
    expect(comparisons, 2);
    expect(lines.join('\n'), isNot(contains('Mismatch')));
  });

  test('mismatches are reported without aborting benchmarks', () async {
    final tester = PerfTester<int, int>(
      testName: 'mismatch',
      testCases: [1],
      implementation1: (n) => n,
      implementation2: (n) => n + 1,
    );
    final lines = await captureOutput(
      () => tester.run(warmupRuns: 0, benchmarkRuns: 2),
    );
    expect(lines.join('\n'), contains('Mismatch on test case 0'));
    expect(tester.impl1Times, hasLength(2));
  });

  test(
    'single implementation supports measurement without verification',
    () async {
      final tester = PerfTester<int, int>.multi(
        testName: 'single',
        testCases: [1, 2],
        implementations: [PerfImpl('Identity', (n) => n)],
      );
      await captureOutput(
        () => tester.run(
          warmupRuns: 0,
          benchmarkRuns: 2,
          skipEqualityCheck: true,
        ),
      );
      expect(tester.implTimes, hasLength(1));
      expect(tester.impl1Times, hasLength(2));
    },
  );
}

void validationAndStateTests() {
  PerfTester<int, int> twoImpls({List<int> cases = const [1, 2, 3]}) =>
      PerfTester<int, int>(
        testName: 'state',
        testCases: cases,
        implementation1: (n) => n,
        implementation2: (n) => n,
      );

  group('argument validation', () {
    test('empty implementations list throws', () {
      expect(
        () => PerfTester<int, int>.multi(
          testName: 'empty',
          testCases: [1],
          implementations: [],
        ),
        throwsArgumentError,
      );
    });

    test('empty testCases throws before running anything', () async {
      var calls = 0;
      final tester = PerfTester<int, int>.multi(
        testName: 'empty cases',
        testCases: [],
        implementations: [PerfImpl('A', (n) => ++calls)],
      );
      await expectLater(tester.run(warmupRuns: 1), throwsArgumentError);
      expect(calls, 0);
    });

    test('bad run counts throw', () async {
      final tester = twoImpls();
      await expectLater(tester.run(benchmarkRuns: 0), throwsRangeError);
      await expectLater(tester.run(warmupRuns: -1), throwsRangeError);
      await expectLater(
        tester.run(profile: true, profileRuns: 0),
        throwsRangeError,
      );
      await expectLater(
        tester.run(profile: true, profileTopN: -1),
        throwsRangeError,
      );
    });

    test('profile counts are ignored when profiling is off', () async {
      await captureOutput(
        () => twoImpls().run(
          warmupRuns: 0,
          benchmarkRuns: 1,
          profileRuns: 0,
          profileTopN: -1,
        ),
      );
    });
  });

  test('one benchmark run reports n/a instead of NaN', () async {
    final lines = await captureOutput(
      () => twoImpls().run(warmupRuns: 0, benchmarkRuns: 1),
    );
    final output = lines.join('\n');
    expect(output, isNot(contains('NaN')));
    expect(
      lines.singleWhere((line) => line.contains('Std Dev')),
      contains('n/a'),
    );
  });

  test('repeated runs replace samples instead of accumulating', () async {
    final tester = twoImpls();
    await captureOutput(() => tester.run(warmupRuns: 0, benchmarkRuns: 3));
    await captureOutput(() => tester.run(warmupRuns: 0, benchmarkRuns: 2));
    expect(tester.impl1Times, hasLength(2));
    expect(tester.impl2Times, hasLength(2));
  });

  test('repeated runs warm up with the same inputs', () async {
    final seen = <List<int>>[];
    late List<int> current;
    final tester = PerfTester<int, int>.multi(
      testName: 'warmup',
      testCases: List.generate(50, (i) => i),
      implementations: [PerfImpl('A', (n) => (current..add(n)).length)],
    );
    for (var i = 0; i < 2; i++) {
      current = <int>[];
      seen.add(current);
      await captureOutput(
        () => tester.run(
          warmupRuns: 20,
          benchmarkRuns: 1,
          minSampleTime: Duration.zero,
        ),
      );
    }
    expect(seen[0], seen[1]);
  });

  test('implTimes stay in measurement order after stats are printed', () async {
    // Each call is faster than the last, so ascending order is not run
    // order. The steps are large: a CI runner can pause for 60 ms, and a
    // Windows timer ticks every 15.6 ms.
    var delayMs = 300;
    final tester = PerfTester<int, int>.multi(
      testName: 'order',
      testCases: [1],
      implementations: [
        PerfImpl('A', (n) async {
          await Future<void>.delayed(Duration(milliseconds: delayMs));
          delayMs = delayMs ~/ 3;
          return n;
        }),
      ],
    );
    await captureOutput(
      () => tester.run(
        warmupRuns: 0,
        benchmarkRuns: 3,
        minSampleTime: Duration.zero,
      ),
    );
    final times = tester.impl1Times;
    expect(times.first, greaterThan(times.last));
  });

  test('single implementation skips verification', () async {
    var calls = 0;
    final tester = PerfTester<int, int>.multi(
      testName: 'single',
      testCases: [1, 2],
      implementations: [PerfImpl('A', (n) => ++calls)],
    );
    final lines = await captureOutput(
      () => tester.run(
        warmupRuns: 0,
        benchmarkRuns: 1,
        minSampleTime: Duration.zero,
      ),
    );
    final output = lines.join('\n');
    expect(output, isNot(contains('Verify')));
    expect(output, isNot(contains('match across')));
    expect(calls, 2, reason: 'only the benchmark pass should call it');
  });

  test('impl2Times throws with one implementation', () {
    final tester = PerfTester<int, int>.multi(
      testName: 'single',
      testCases: [1],
      implementations: [PerfImpl('A', (n) => n)],
    );
    expect(() => tester.impl2Times, throwsStateError);
  });

  group('profileFileNames', () {
    test('includes the test name', () {
      expect(profileFileNames('My test', ['Fast']), [
        'cpu_profile_My_test__Fast.json',
      ]);
    });

    test('names that sanitize the same get numeric suffixes', () {
      expect(profileFileNames('t', ['A B', 'A_B', 'A.B']), [
        'cpu_profile_t__A_B.json',
        'cpu_profile_t__A_B_2.json',
        'cpu_profile_t__A_B_3.json',
      ]);
    });

    test('names that differ only in case do not collide', () {
      expect(profileFileNames('t', ['fast', 'FAST']), [
        'cpu_profile_t__fast.json',
        'cpu_profile_t__FAST_2.json',
      ]);
    });
  });
}
