// Run: dart run example/async_comparison.dart
import 'dart:convert';
import 'package:perf_tester/perf_tester.dart';

Future<void> main() async {
  final tester = PerfTester<String, List<int>>.multi(
    testName: 'Decode integer arrays (sync and async)',
    testCases: [
      for (final size in [100, 1000, 10000])
        jsonEncode(List.generate(size, (index) => index)),
    ],
    implementations: [
      PerfImpl('Sync', (input) => (jsonDecode(input) as List).cast<int>()),
      PerfImpl(
        'Async',
        (input) async => (jsonDecode(input) as List).cast<int>(),
      ),
      PerfImpl(
        'Future',
        (input) => Future(() => (jsonDecode(input) as List).cast<int>()),
      ),
    ],
    equalityCheck: (a, b) =>
        a != null &&
        b != null &&
        a.length == b.length &&
        Iterable.generate(a.length).every((i) => a[i] == b[i]),
  );
  await tester.run(warmupRuns: 10, benchmarkRuns: 20);
}
