// Run: dart run example/perf_tester_example.dart
import 'package:perf_tester/perf_tester.dart';

int loopSum(List<int> values) {
  var sum = 0;
  for (final value in values) {
    sum += value;
  }
  return sum;
}

int foldSum(List<int> values) => values.fold(0, (sum, value) => sum + value);

Future<void> main() async {
  await PerfTester<List<int>, int>(
    testName: 'Sum integer lists',
    testCases: [
      for (final size in [1000, 10000, 100000])
        List.generate(size, (index) => index % 100),
    ],
    implementation1: loopSum,
    implementation2: foldSum,
    impl1Name: 'Loop',
    impl2Name: 'Fold',
  ).run(warmupRuns: 20, benchmarkRuns: 30);
}
