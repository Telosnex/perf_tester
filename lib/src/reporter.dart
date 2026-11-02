import 'results.dart';

/// Receives progress and results from [PerfTester.run].
///
/// [PerfTester.run] calls the methods in this order:
///
/// 1. [runStarted]
/// 2. If verification runs: [verifyStarted], then [mismatchFound] once per
///    mismatch, then [verifyFinished].
/// 3. [warmupStarted], then [warmupFinished].
/// 4. [benchmarkStarted], then [benchmarkProgress] once per benchmark run,
///    then [benchmarkFinished].
/// 5. If profiling was requested: either [profileUnavailable], or
///    [profileStarted] followed by [profileCaptured] once per
///    implementation.
/// 6. [runFinished].
///
/// If an implementation throws, the run stops and later methods are not
/// called. Every method does nothing by default, so a subclass only
/// overrides the events it needs.
abstract class PerfReporter {
  const PerfReporter();

  void runStarted(PerfRunPlan plan) {}

  void verifyStarted() {}

  void mismatchFound(Mismatch<Object?, Object?> mismatch) {}

  void verifyFinished(VerificationResult<Object?, Object?> verification) {}

  void warmupStarted(int runs) {}

  void warmupFinished(Duration elapsed) {}

  void benchmarkStarted(int runs, int testCaseCount) {}

  /// [completedRuns] goes from 1 to [totalRuns]. [elapsed] is the time of
  /// the run that just finished, across all implementations.
  void benchmarkProgress(int completedRuns, int totalRuns, Duration elapsed) {}

  /// [comparisons] has one entry per implementation after the first.
  void benchmarkFinished(
    List<ImplResult> implementations,
    List<Comparison> comparisons,
  ) {}

  /// Profiling was requested, but the VM service could not be used.
  void profileUnavailable(String reason) {}

  /// The VM service is connected, and profiling is about to start.
  void profileStarted() {}

  void profileCaptured(ProfileResult profile) {}

  void runFinished(PerfResult<Object?, Object?> result) {}
}

/// A [PerfReporter] that ignores every event.
final class SilentReporter extends PerfReporter {
  const SilentReporter();
}
