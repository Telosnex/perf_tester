import 'dart:async';
import 'dart:math' as math;

import 'console_reporter.dart';
import 'encode.dart';
import 'perf_profiler.dart';
import 'reporter.dart';
import 'results.dart';

/// A named implementation entry for [PerfTester].
class PerfImpl<Input, Output> {
  final String name;
  final FutureOr<Output?> Function(Input) fn;
  const PerfImpl(this.name, this.fn);
}

/// Small utility for comparing implementations on the same inputs.
///
/// Supports one or more implementations (a single implementation is allowed
/// for pure measurement/profiling runs). When two or more are given, the
/// first implementation in the list is treated as the **baseline** for
/// comparison.
///
/// ## Two-implementation usage (original API)
///
/// ```dart
/// final tester = PerfTester<String, dynamic>(
///   testName: 'my test',
///   testCases: inputs,
///   implementation1: fnA,
///   implementation2: fnB,
///   impl1Name: 'Baseline',
///   impl2Name: 'Candidate',
/// );
/// ```
///
/// ## Multi-implementation usage
///
/// ```dart
/// final tester = PerfTester<String, dynamic>.multi(
///   testName: 'my test',
///   testCases: inputs,
///   implementations: [
///     PerfImpl('Baseline', fnA),
///     PerfImpl('Candidate B', fnB),
///     PerfImpl('Candidate C', fnC),
///   ],
/// );
/// ```
///
/// It verifies output parity first, then runs a warmup phase and a benchmark
/// phase. [run] returns a [PerfResult] and sends progress to a
/// [PerfReporter], which prints a text summary by default.
///
/// ## Testing after you've already edited the file
///
/// The most common scenario: you've already changed a method and want to
/// benchmark old vs new. The old code lives in `git diff` — here's how to
/// recover it.
///
/// 1. **Extract the old version** next to the current one:
///    ```bash
///    # Dump the committed (pre-edit) file:
///    git show HEAD:lib/path/to/foo.dart > test/perf/foo_old.dart
///    ```
///    Then trim it to just the function(s) you care about. Remove
///    framework imports that won't resolve in a plain `dart run` context.
///
/// 2. **Extract the new version** the same way — copy the function(s) from
///    the working-tree file into `test/perf/foo_new.dart`.
///
///    Why copy both instead of importing the real file? If the real file
///    has framework imports (Flutter, provider, etc.) and you want to run
///    outside Flutter, standalone copies keep the test runnable with
///    `dart run`. If you're fine using `flutter test`, you can import
///    the real file directly.
///
/// 3. **Make private methods public** in the copies. The copies are
///    throwaway test scaffolding — visibility doesn't matter.
///
/// 4. **Import with prefixes** in your perf test:
///    ```dart
///    import 'foo_old.dart' as old;
///    import 'foo_new.dart' as current;
///    ```
///
/// 5. **Wire into PerfTester** as `implementation1` / `implementation2`
///    or entries in the `implementations` list.
///
/// 6. **Run:**
///    ```bash
///    # Pure Dart:
///    dart run test/perf/some_perf_test.dart
///
///    # Flutter (code imports flutter packages):
///    flutter test test/perf/some_perf_test.dart
///
///    # Flutter + CPU profiling:
///    flutter test --enable-vmservice --no-dds test/perf/some_perf_test.dart
///    ```
class PerfTester<Input, Output> {
  /// A short label used in the benchmark output.
  final String testName;

  /// Inputs that will be fed to all implementations.
  final List<Input> testCases;

  /// All implementations being compared. The first is the baseline.
  final List<PerfImpl<Input, Output>> implementations;

  /// Optional custom equality check for result comparison.
  final bool Function(Output?, Output?)? equalityCheck;

  /// Seed for selecting warmup inputs. Each [run] starts a new generator
  /// with this seed, so repeated runs warm up with the same inputs.
  static const _warmupSeed = 42;

  /// Measured runtime samples per implementation, in milliseconds, in the
  /// order they were measured. Index corresponds to [implementations] index.
  ///
  /// Each [run] clears the samples from the previous run.
  late final List<List<double>> implTimes = List.generate(
    implementations.length,
    (_) => <double>[],
  );

  // Legacy accessors for 2-impl callers.
  List<double> get impl1Times => implTimes[0];

  /// Samples for the second implementation.
  ///
  /// Throws a [StateError] if there is only one implementation.
  List<double> get impl2Times {
    if (implTimes.length < 2) {
      throw StateError(
        'impl2Times needs at least 2 implementations; '
        'this tester has ${implTimes.length}.',
      );
    }
    return implTimes[1];
  }

  /// Original constructor: compares exactly two implementations.
  PerfTester({
    required this.testName,
    required this.testCases,
    required FutureOr<Output?> Function(Input) implementation1,
    required FutureOr<Output?> Function(Input) implementation2,
    String impl1Name = 'Original',
    String impl2Name = 'Optimized',
    this.equalityCheck,
  }) : implementations = [
         PerfImpl(impl1Name, implementation1),
         PerfImpl(impl2Name, implementation2),
       ];

  /// Multi-implementation constructor: measures one or more implementations.
  /// With two or more, the first in the list is the baseline.
  PerfTester.multi({
    required this.testName,
    required this.testCases,
    required this.implementations,
    this.equalityCheck,
  }) {
    if (implementations.isEmpty) {
      throw ArgumentError.value(
        implementations,
        'implementations',
        'Need at least 1 implementation',
      );
    }
  }

  // ── Public entry point ──────────────────────────────────────────────

  /// Runs the full comparison flow.
  ///
  /// The default flow is: verify outputs, warm up all implementations, then
  /// benchmark them. Returns everything that was measured.
  ///
  /// Progress and results go to [reporter]. The default is a new
  /// [ConsoleReporter], which prints a text summary. Pass a
  /// [SilentReporter] to print nothing.
  ///
  /// Mismatched outputs do not stop the run. Check
  /// [PerfResult.verification] to fail on them.
  ///
  /// ## CPU profiling
  ///
  /// Set [profile] to `true` to collect a CPU sample profile during the
  /// benchmark phase and print the top-N hottest functions afterward.
  ///
  /// ### Pure Dart tests
  ///
  /// ```bash
  /// dart run --enable-vm-service test/perf/some_perf_test.dart
  /// ```
  ///
  /// ### Flutter tests (code depends on Flutter)
  ///
  /// Flutter tests need two extra flags and one code change:
  ///
  /// ```bash
  /// flutter test --enable-vmservice --no-dds test/perf/some_perf_test.dart
  /// ```
  ///
  /// Why both flags:
  /// - `--enable-vmservice` starts the VM service (off by default in tests).
  /// - `--no-dds` disables the Dart Development Service, which otherwise
  ///   puts the VM service in single-client mode and silently drops our
  ///   WebSocket connection (causing an infinite hang).
  ///
  /// In your test, pass `tester.runAsync` to escape the fake async zone
  /// that Flutter's test framework uses. Without it, the VM service
  /// WebSocket connection (real I/O) never completes:
  ///
  /// ```dart
  /// testWidgets('perf', (tester) async {
  ///   await myTester.run(
  ///     profile: true,
  ///     runAsync: tester.runAsync,
  ///   );
  /// });
  /// ```
  ///
  /// Only the VM-service I/O (connect/clear/collect) runs inside `runAsync`;
  /// implementation invocations run in the normal test zone, so impls that
  /// call `tester.pump*` are fine.
  ///
  /// Without the VM service flags, profiling is silently skipped and the
  /// benchmark runs normally.
  ///
  /// [profileSaveDir], when set, additionally writes each implementation's
  /// samples as DevTools cpu-profiler JSON to
  /// `<profileSaveDir>/cpu_profile_<testName>__<implName>.json` for offline
  /// analysis. See [profileFileNames].
  ///
  /// Throws an [ArgumentError] if [testCases] is empty, [warmupRuns] is
  /// negative, or [benchmarkRuns] is less than 1. When [profile] is true,
  /// [profileRuns] must be at least 1 and [profileTopN] must not be negative.
  Future<PerfResult<Input, Output>> run({
    int warmupRuns = 100,
    int benchmarkRuns = 100,
    bool skipEqualityCheck = false,
    bool profile = false,
    int profileTopN = 50,
    int profileRuns = 100,
    String? profileSaveDir,
    PerfReporter? reporter,

    /// Pass `tester.runAsync` when running inside a Flutter widget test.
    /// Real I/O (VM service connection) needs to escape the fake async zone.
    Future<T?> Function<T>(
      Future<T> Function() callback, {
      Duration additionalTime,
    })?
    runAsync,
  }) async {
    if (testCases.isEmpty) {
      throw ArgumentError.value(testCases, 'testCases', 'Must not be empty');
    }
    RangeError.checkNotNegative(warmupRuns, 'warmupRuns');
    if (benchmarkRuns < 1) {
      throw RangeError.value(benchmarkRuns, 'benchmarkRuns', 'Must be >= 1');
    }
    if (profile) {
      if (profileRuns < 1) {
        throw RangeError.value(profileRuns, 'profileRuns', 'Must be >= 1');
      }
      RangeError.checkNotNegative(profileTopN, 'profileTopN');
    }

    final out = reporter ?? ConsoleReporter();

    // Each run is independent of earlier runs.
    for (final times in implTimes) {
      times.clear();
    }

    // With one implementation there is nothing to compare against.
    final verify = !skipEqualityCheck && implementations.length > 1;

    out.runStarted(
      PerfRunPlan(
        testName: testName,
        implementationNames: [for (final impl in implementations) impl.name],
        testCaseCount: testCases.length,
        warmupRuns: warmupRuns,
        benchmarkRuns: benchmarkRuns,
        phases: [
          if (verify) PerfPhase.verify,
          PerfPhase.warmup,
          PerfPhase.benchmark,
          if (profile) PerfPhase.profile,
        ],
      ),
    );

    // ── Verify ──
    final VerificationResult<Input, Output> verification;
    if (verify) {
      out.verifyStarted();
      verification = await _verifyImplementations(out);
      out.verifyFinished(verification);
    } else {
      verification = VerificationResult.skipped(
        implementationCount: implementations.length,
      );
    }

    // ── Warmup ──
    out.warmupStarted(warmupRuns);
    final warmupTime = await _warmup(warmupRuns, math.Random(_warmupSeed));
    out.warmupFinished(warmupTime);

    // ── Benchmark ──
    out.benchmarkStarted(benchmarkRuns, testCases.length);
    await _benchmark(benchmarkRuns, out);
    final implResults = [
      for (var k = 0; k < implementations.length; k++)
        ImplResult(
          name: implementations[k].name,
          samples: implTimes[k],
          casesPerSample: testCases.length,
        ),
    ];
    out.benchmarkFinished(implResults);

    // ── Profile ──
    var profileStatus = ProfileStatus.notRequested;
    String? profileUnavailableReason;
    final profiles = <ProfileResult>[];
    if (profile) {
      // Real I/O (VM service websocket) must run outside the fake async
      // zone; implementation invocations must stay INSIDE it (widget-test
      // impls call tester.pump*, which is illegal within runAsync).
      Future<T?> io<T>(Future<T> Function() fn) {
        if (runAsync != null) return runAsync(fn);
        return fn();
      }

      final profiler = PerfProfiler();
      try {
        final connected = await io(profiler.connect) ?? false;
        if (connected) {
          profileStatus = ProfileStatus.captured;
          out.profileStarted();
          final fileNames = profileFileNames(
            testName,
            implementations.map((impl) => impl.name).toList(),
          );
          for (var k = 0; k < implementations.length; k++) {
            final impl = implementations[k];
            await io(profiler.clearSamples);
            for (int r = 0; r < profileRuns; r++) {
              for (final input in testCases) {
                await _invoke(impl.fn, input);
              }
            }
            // One snapshot, shared by the summary and the saved JSON:
            // fetching twice makes the second fetch profile the first.
            await io(profiler.capture);
            final savedFile = profileSaveDir == null
                ? null
                : await io(
                    () => profiler.saveAsDevToolsJson(
                      '$profileSaveDir/${fileNames[k]}',
                    ),
                  );
            final summary = await io(
              () => profiler.summarize(
                implementationName: impl.name,
                topN: profileTopN,
                savedFile: savedFile,
              ),
            );
            if (summary != null) {
              profiles.add(summary);
              out.profileCaptured(summary);
            }
          }
        } else {
          profileStatus = ProfileStatus.unavailable;
          profileUnavailableReason =
              profiler.unavailableReason ??
              'VM service connection did not complete.';
          out.profileUnavailable(profileUnavailableReason);
        }
      } finally {
        // An open VM service connection keeps the process alive, so close it
        // even when an implementation throws.
        await io(profiler.dispose);
      }
    }

    final result = PerfResult<Input, Output>(
      testName: testName,
      testCaseCount: testCases.length,
      warmupRuns: warmupRuns,
      benchmarkRuns: benchmarkRuns,
      implementations: implResults,
      verification: verification,
      profileStatus: profileStatus,
      profileUnavailableReason: profileUnavailableReason,
      profiles: profiles,
    );
    out.runFinished(result);
    return result;
  }

  // ── Verify ────────────────────────────────────────────────────────────

  /// Executes all implementations for every test case and checks that the
  /// outputs match the baseline (first implementation).
  Future<VerificationResult<Input, Output>> _verifyImplementations(
    PerfReporter out,
  ) async {
    final mismatches = <Mismatch<Input, Output>>[];
    final baseline = implementations[0];
    final check = equalityCheck;

    for (var i = 0; i < testCases.length; i++) {
      final input = testCases[i];
      final baseResult = await _invoke(baseline.fn, input);
      // Encode only when comparing encodings; a custom check does not need
      // it, and encoding large outputs is slow.
      final baseEncoded = check == null ? safeEncode(baseResult) : null;

      for (var k = 1; k < implementations.length; k++) {
        final impl = implementations[k];
        final result = await _invoke(impl.fn, input);
        final isEqual = check != null
            ? check(baseResult, result)
            : baseEncoded == safeEncode(result);

        if (!isEqual) {
          final mismatch = Mismatch<Input, Output>(
            caseIndex: i,
            input: input,
            baselineName: baseline.name,
            baselineOutput: baseResult,
            implementationName: impl.name,
            implementationOutput: result,
          );
          mismatches.add(mismatch);
          out.mismatchFound(mismatch);
        }
      }
    }

    return VerificationResult(
      mismatches: mismatches,
      caseCount: testCases.length,
      implementationCount: implementations.length,
    );
  }

  // ── Warmup ────────────────────────────────────────────────────────────

  /// Performs a short warmup using random test cases to reduce cold-start
  /// effects before the timed benchmark begins.
  Future<Duration> _warmup(int runs, math.Random random) async {
    final sw = Stopwatch()..start();
    for (var i = 0; i < runs; i++) {
      final input = testCases[random.nextInt(testCases.length)];
      for (final impl in implementations) {
        await _invoke(impl.fn, input);
      }
    }
    sw.stop();
    return sw.elapsed;
  }

  // ── Benchmark ─────────────────────────────────────────────────────────

  /// Measures all implementations across the full test suite.
  ///
  /// The order of implementations is rotated each run to reduce bias from
  /// cache or VM effects.
  Future<void> _benchmark(int runs, PerfReporter out) async {
    final n = implementations.length;

    for (var run = 0; run < runs; run++) {
      final runIterationSw = Stopwatch()..start();

      // Build a rotated order for this run to reduce ordering bias.
      final order = List.generate(n, (k) => (k + run) % n);

      final stopwatches = List.generate(n, (_) => Stopwatch());

      for (final idx in order) {
        final sw = stopwatches[idx]..start();
        for (var input in testCases) {
          await _invoke(implementations[idx].fn, input);
        }
        sw.stop();
      }

      for (var idx = 0; idx < n; idx++) {
        implTimes[idx].add(stopwatches[idx].elapsedMicroseconds / 1000.0);
      }

      runIterationSw.stop();
      out.benchmarkProgress(run + 1, runs, runIterationSw.elapsed);
    }
  }

  Future<Output?> _invoke(
    FutureOr<Output?> Function(Input) implementation,
    Input input,
  ) async {
    final result = implementation(input);
    if (result is Future<Output?>) {
      return await result;
    }
    return result;
  }
}

/// Returns one DevTools profile file name per entry in [implNames].
///
/// Names include the sanitized [testName], so testers that save to the same
/// directory do not overwrite each other. If two implementation names
/// sanitize to the same file name, later ones get a numeric suffix.
List<String> profileFileNames(String testName, List<String> implNames) {
  String sanitize(String name) =>
      name.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
  final used = <String>{};
  return [
    for (final implName in implNames)
      () {
        final base = 'cpu_profile_${sanitize(testName)}__${sanitize(implName)}';
        var candidate = base;
        for (var i = 2; !used.add(candidate.toLowerCase()); i++) {
          candidate = '${base}_$i';
        }
        return '$candidate.json';
      }(),
  ];
}
