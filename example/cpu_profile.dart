// Run: dart run --enable-vm-service=0 example/cpu_profile.dart
// Profiles are written to profiles/cpu_profile_Prime_counting_CPU_profile__Prime_count.json.
// Without the VM service, the benchmark runs but profiling is skipped.
import 'package:perf_tester/perf_tester.dart';

int countPrimes(int limit) {
  var count = 0;
  for (var n = 2; n <= limit; n++) {
    var prime = true;
    for (var divisor = 2; divisor * divisor <= n; divisor++) {
      if (n % divisor == 0) {
        prime = false;
        break;
      }
    }
    if (prime) count++;
  }
  return count;
}

Future<void> main() async {
  await PerfTester<int, int>.multi(
    testName: 'Prime counting CPU profile',
    testCases: [20000, 40000, 80000],
    implementations: [PerfImpl('Prime count', countPrimes)],
  ).run(
    warmupRuns: 5,
    benchmarkRuns: 10,
    profile: true,
    profileRuns: 100,
    profileTopN: 10,
    profileSaveDir: 'profiles',
  );
}
