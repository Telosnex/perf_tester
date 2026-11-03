# perf_tester

Compare two or more Dart or Flutter implementations on the same inputs.

`perf_tester` does these steps:

1. It makes sure that all implementations give the same output.
2. It warms up and times each implementation.
3. It tests whether the difference in speed is significant.
4. It can record a CPU profile for each implementation.

`dart run perf_tester:aot` runs the comparison ahead-of-time (AOT) compiled.
Under the JIT, identical code can differ in speed by up to 1.5x. Thus, use
AOT results to make decisions.

## Install

Add the package as a dev dependency:

```bash
dart pub add dev:perf_tester
```

For a Flutter project, use `flutter pub add dev:perf_tester`.

## Compare two implementations

```dart
import 'package:perf_tester/perf_tester.dart';

int sumLoop(List<int> xs) {
  var sum = 0;
  for (final x in xs) {
    sum += x;
  }
  return sum;
}

int sumFold(List<int> xs) => xs.fold(0, (a, b) => a + b);

Future<void> main() async {
  await PerfTester<List<int>, int>(
    testName: 'Sum a list',
    testCases: [
      for (final n in [1000, 10000, 100000]) List.generate(n, (i) => i),
    ],
    implementation1: sumLoop,
    implementation2: sumFold,
    impl1Name: 'Loop',
    impl2Name: 'Fold',
  ).run();
}
```

The first implementation is the baseline. The console output shows a
results table, a verdict for each implementation, and a timing histogram:

```text
      Comparison (Mann-Whitney U, two-sided, α = 0.05):
      Fold vs Loop: 6.40x slower (median), p < 0.001
```

To compare more than two implementations, use `PerfTester.multi`:

```dart
PerfTester<String, Object?>.multi(
  testName: 'Parse',
  testCases: inputs,
  implementations: [
    PerfImpl('Baseline', parseA),
    PerfImpl('Candidate B', parseB),
    PerfImpl('Candidate C', parseC),
  ],
);
```

An implementation can return a value or a `Future`. The package awaits only
results that are futures.

## Run AOT

```bash
dart run perf_tester:aot test/perf/sum_perf_test.dart
```

The command accepts one or more files or directories. A directory gives all
`*_test.dart` files below it. A file can be one of these:

- a script with a `main` function
- a `package:test` file
- a `flutter_test` file, with `testWidgets` included

For pure Dart files, the command uses `dart compile exe`. For files that need
Flutter, it builds a Flutter desktop app in profile mode and runs the app.
The command finds Flutter from the imports, or from a build error about
`dart:ui`. Several files share one build. Each file then runs in its own
process, so state from one file does not go to the next file.

Flutter test files run as they do with `flutter test`. They use the
automated test binding with fake time. They also use the nearest
`flutter_test_config.dart`.

The command exits with 0 only if every file exits with 0. A test file exits
with 0 only if all its tests pass.

Options:

| Option | Effect |
|---|---|
| `--dart` | Build with `dart compile exe`. |
| `--flutter` | Build a Flutter app in profile mode. |
| `-D`, `--dart-define=<key=value>` | Define a constant. You can repeat this option. |
| `--dart-define-from-file=<path>` | Define constants from a `.env` or `.json` file. |
| `-- <args>` | Send arguments to `main`. This works only with one pure Dart file. |

Flutter builds need these items:

- The desktop folder for your computer (`macos`, `linux`, or `windows`). To
  add it, run `flutter create --platforms=macos .`
- On macOS, CPU profiling needs `com.apple.security.network.client` in
  `macos/Runner/DebugProfile.entitlements`. The default Flutter template
  does not have this entitlement.

CAUTION: The Flutter build writes to `build/`. It replaces the profile build
of your app that is in `build/`.

## Use the result

`run()` returns a `PerfResult`. You can use it to fail a script or a test:

```dart
final result = await tester.run(reporter: const SilentReporter());

if (result.verification.failed) {
  throw StateError('The outputs are not the same.');
}
final comparison = result.comparisons.single;
if (comparison.verdict != ComparisonVerdict.faster) {
  throw StateError('${comparison.implementationName} is not faster.');
}
```

`PerfResult` has these values:

| Value | Contents |
|---|---|
| `implementations` | Samples and statistics for each implementation: `median`, `mean`, `min`, `max`, `stdDev`, `opsPerSecond`. |
| `comparisons` | One `Comparison` for each implementation after the baseline: `verdict`, `speedup`, `pValue`, `probabilityFaster`. |
| `verification` | `passed`, `failed`, or `skipped`, and each `Mismatch`. |
| `compilationMode` | `jit` or `aot`. |
| `profiles` | The top functions for each implementation, and the saved file. |

## Timing

Each sample times one or more passes over all test cases. If one pass of an
implementation takes less than `minSampleTime` (1 ms by default), each sample
times more passes. The package then divides the time by the number of
passes. Thus, timer resolution and loop overhead do not change the result for
fast code. `ImplResult.passesPerSample` gives the number of passes.

The order of implementations changes on each benchmark run. This decreases
bias from caches and from the VM.

## Comparisons

The package compares each implementation to the baseline with a two-sided
Mann-Whitney U test. This test does not assume a normal distribution, and a
small number of outliers do not change the result much. The verdict is one
of these:

| Verdict | Meaning |
|---|---|
| `faster` | The implementation is significantly faster than the baseline. |
| `slower` | The implementation is significantly slower than the baseline. |
| `noSignificantDifference` | The samples overlap too much to show which one is faster. |
| `tooFewSamples` | No result can be significant with this number of samples. At the default level of 0.05, you need 4 benchmark runs or more. |

Set `significanceLevel` in `run()` to change the level.

### JIT and AOT

Under the JIT (`dart run`, `dart test`, `flutter test`), two copies of
identical code can run at different speeds. In tests on an Apple M4 Max, the
ratio was between 0.70 and 1.46, and it changed during a run. The same code
compiled AOT stayed between 0.99 and 1.01. The significance test cannot know
about this difference, so it can report a JIT difference as significant.

`PerfResult.compilationMode` gives the mode. Under the JIT, the console shows
a warning below the verdicts. Use `perf_tester:aot` for results that you
make decisions on.

## CPU profiles

```dart
await tester.run(profile: true, profileSaveDir: 'profiles');
```

The profiler runs each implementation separately and prints its top
functions by self time. If you set `profileSaveDir`, the profiler also writes
a DevTools CPU profile for each implementation. The file name is
`cpu_profile_<testName>__<implName>.json`.

Profiling needs the VM service:

| How you run | VM service |
|---|---|
| `dart run --enable-vm-service file.dart` | Yes |
| `flutter test --enable-vmservice --no-dds file_test.dart` | Yes |
| `perf_tester:aot` with a Flutter file | Yes (profile mode) |
| `perf_tester:aot` with a pure Dart file | No. `dart compile exe` has no VM service. |

If the VM service is not available, the run continues without a profile.
`PerfResult.profileUnavailableReason` gives the cause.

In a `testWidgets` test, give `tester.runAsync` to `run()`. The profiler uses
it for real I/O:

```dart
await tester.run(profile: true, runAsync: widgetTester.runAsync);
```

## Output

`ConsoleReporter` is the default. It prints with `print`. To send lines to a
different place, give it a `printLine` function. `SilentReporter` prints
nothing. To make a different format, extend `PerfReporter` and override the
events that you need.

## Limits

- The package needs `dart:io`. It works on Linux, macOS, and Windows. It does
  not work on the web.
- Each implementation is compared only to the baseline. The package does not
  correct for multiple comparisons.
- On a shared CI machine, other processes change the timings. The package
  runs the implementations alternately in one process, which decreases this
  effect.

## License

MIT. See [LICENSE](LICENSE).
