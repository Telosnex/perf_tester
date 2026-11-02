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
      () => tester.run(warmupRuns: 2, benchmarkRuns: 3),
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
