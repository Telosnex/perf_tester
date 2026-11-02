// Run: dart run example/result_check.dart
//
// Uses the returned PerfResult instead of the printed report: the script
// prints one line and sets a failing exit code if the candidate gives
// different output or is not significantly faster than the baseline.
import 'dart:io';

import 'package:perf_tester/perf_tester.dart';

String joinWithPlus(List<String> words) {
  var out = '';
  for (final word in words) {
    out += word;
  }
  return out;
}

String joinWithBuffer(List<String> words) {
  final buffer = StringBuffer();
  words.forEach(buffer.write);
  return buffer.toString();
}

Future<void> main() async {
  final result = await PerfTester<List<String>, String>(
    testName: 'Join strings',
    testCases: [
      for (final size in [100, 1000, 5000])
        List.generate(size, (index) => 'word$index '),
    ],
    implementation1: joinWithPlus,
    implementation2: joinWithBuffer,
    impl1Name: 'Plus',
    impl2Name: 'Buffer',
  ).run(warmupRuns: 10, benchmarkRuns: 30, reporter: const SilentReporter());

  if (result.verification.failed) {
    stderr.writeln('FAIL: outputs differ');
    exitCode = 1;
    return;
  }

  final comparison = result.comparisons.single;
  final summary = switch (comparison.verdict) {
    ComparisonVerdict.faster =>
      '${comparison.speedup.toStringAsFixed(2)}x faster',
    ComparisonVerdict.slower =>
      '${(1 / comparison.speedup).toStringAsFixed(2)}x slower',
    ComparisonVerdict.noSignificantDifference => 'no significant difference',
    ComparisonVerdict.tooFewSamples => 'too few runs to compare',
  };
  final p = comparison.pValue;
  print(
    '${comparison.implementationName} vs ${comparison.baselineName}: '
    '$summary (${p < 0.001 ? 'p < 0.001' : 'p = ${p.toStringAsFixed(3)}'})',
  );
  if (comparison.verdict != ComparisonVerdict.faster) {
    stderr.writeln('FAIL: ${comparison.implementationName} is not faster');
    exitCode = 1;
  }
}
