## 1.0.0

- First stable release.

## 0.1.2

- Excludes build and platform folders from analysis, as Flutter 3.47 does.
  No code changes.

## 0.1.1

- `perf_tester:aot --dart` now fails, and prints the build error, when the
  code needs `dart:ui`. Before, it printed nothing and exited with 0.

## 0.1.0

First release.

- `PerfTester` compares two or more implementations on the same inputs.
  It checks that their outputs match, warms them up, and times them.
- `run()` returns a `PerfResult` with raw samples, statistics, the
  verification result, comparisons, and CPU profiles.
- Fast implementations get several passes per sample, so each sample takes
  at least `minSampleTime`. Synchronous results are not awaited.
- Each implementation is compared to the first with a two-sided
  Mann-Whitney U test. The verdict is faster, slower, no significant
  difference, or too few samples.
- `ConsoleReporter` prints a results table, comparisons, and timing
  histograms. `SilentReporter` prints nothing. Extend `PerfReporter` for
  other output.
- CPU profiling through the VM service, with an optional DevTools JSON file
  per implementation.
- `PerfResult.compilationMode` tells whether the run was JIT or AOT. Under
  the JIT, the console warns that comparisons can be wrong.
- `dart run perf_tester:aot` builds Dart or Flutter files AOT and runs
  them. It accepts scripts, `package:test` files, and `flutter_test` files
  with `testWidgets`. Several files share one build, and each runs in its
  own process.
