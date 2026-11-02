// Run by test/profiling_test.dart in a child process with the VM service
// enabled. Usage: profile_fixture.dart <throw|save> <outputDir>
import 'package:perf_tester/perf_tester.dart';

Future<void> main(List<String> args) async {
  final mode = args[0];
  final outputDir = args[1];
  var calls = 0;

  int work(int n) {
    // Throw during profiling. The benchmark makes 2 calls (1 run, 1 case,
    // 2 implementations); verify and warmup are off.
    if (mode == 'throw' && ++calls > 2) throw StateError('boom');
    var sum = 0;
    for (var i = 0; i < n; i++) {
      sum += i % 7;
    }
    return sum;
  }

  final tester = PerfTester<int, int>.multi(
    testName: 'Fixture test',
    testCases: [20000],
    implementations: [PerfImpl('A B', work), PerfImpl('A_B', work)],
  );
  try {
    await tester.run(
      warmupRuns: 0,
      benchmarkRuns: 1,
      skipEqualityCheck: true,
      profile: true,
      profileRuns: mode == 'throw' ? 1 : 20,
      profileTopN: 3,
      profileSaveDir: outputDir,
    );
  } on StateError catch (e) {
    print('FIXTURE_CAUGHT: ${e.message}');
  }
  print('FIXTURE_DONE');
}
