// Prints console output for a fixed set of scenarios, with every number
// replaced by "#". Used to check that reporter changes keep the output.
// Run: dart run tool/output_snapshot.dart
import 'dart:async';

import 'package:perf_tester/perf_tester.dart';

Future<void> main() async {
  final lines = <String>[];
  Future<void> capture(Future<void> Function() body) => runZoned(
    body,
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) => lines.add(line),
    ),
  );

  await capture(
    () => PerfTester<int, int>(
      testName: 'two match',
      testCases: [1, 2, 3],
      implementation1: (n) => n * 2,
      implementation2: (n) => n + n,
    ).run(warmupRuns: 3, benchmarkRuns: 12),
  );
  await capture(
    () => PerfTester<int, int>(
      testName: 'short mismatch',
      testCases: [1, 2],
      implementation1: (n) => n,
      implementation2: (n) => n == 2 ? 99 : n,
    ).run(warmupRuns: 0, benchmarkRuns: 2),
  );
  await capture(
    () => PerfTester<int, String>(
      testName: 'long mismatch',
      testCases: [1],
      implementation1: (n) => 'a' * 1500,
      implementation2: (n) => '${'a' * 700}b${'a' * 799}',
    ).run(warmupRuns: 0, benchmarkRuns: 2),
  );
  await capture(
    () => PerfTester<int, int>.multi(
      testName: 'three',
      testCases: [1, 2],
      implementations: [
        PerfImpl('A', (n) => n),
        PerfImpl('Bee', (n) async => n),
        PerfImpl('Sea', (n) => Future(() => n)),
      ],
    ).run(warmupRuns: 2, benchmarkRuns: 5),
  );
  await capture(
    () => PerfTester<int, int>.multi(
      testName: 'single, one run',
      testCases: [1],
      implementations: [PerfImpl('Only', (n) => n)],
    ).run(warmupRuns: 1, benchmarkRuns: 1, profile: true),
  );

  final number = RegExp(r'\d+(\.\d+)?[KM]?');
  final bars = RegExp('│[ ▁▂▃▄▅▆▇█]+│');
  // Timing noise flips these between runs.
  final comparison = RegExp(
    r'↑#% \(#x faster\)|↓#% \(#x slower\)|No difference',
  );
  for (final line in lines) {
    // Column padding depends on number widths; collapse runs of spaces.
    print(
      line
          .replaceAll(bars, '│<bars>│')
          .replaceAll(number, '#')
          .replaceAll(comparison, '<cmp>')
          .replaceAll(RegExp(' {2,}'), '  ')
          .trimRight(),
    );
  }
}
