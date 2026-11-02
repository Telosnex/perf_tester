import 'dart:math' as math;

/// A phase of [PerfTester.run], in the order the phases run.
enum PerfPhase { verify, warmup, benchmark, profile }

/// What a run is about to do. Sent to [PerfReporter.runStarted].
final class PerfRunPlan {
  final String testName;
  final List<String> implementationNames;
  final int testCaseCount;
  final int warmupRuns;
  final int benchmarkRuns;

  /// The phases this run will execute, in order.
  final List<PerfPhase> phases;

  PerfRunPlan({
    required this.testName,
    required List<String> implementationNames,
    required this.testCaseCount,
    required this.warmupRuns,
    required this.benchmarkRuns,
    required List<PerfPhase> phases,
  }) : implementationNames = List.unmodifiable(implementationNames),
       phases = List.unmodifiable(phases);
}

/// One test case where an implementation's output differs from the
/// baseline's output.
final class Mismatch<Input, Output> {
  /// Index into [PerfTester.testCases].
  final int caseIndex;
  final Input input;
  final String baselineName;
  final Output? baselineOutput;
  final String implementationName;
  final Output? implementationOutput;

  const Mismatch({
    required this.caseIndex,
    required this.input,
    required this.baselineName,
    required this.baselineOutput,
    required this.implementationName,
    required this.implementationOutput,
  });
}

enum VerificationStatus {
  /// All implementations produced the baseline's output for every case.
  passed,

  /// At least one output differed. See [VerificationResult.mismatches].
  failed,

  /// Verification did not run: it was turned off, or there was only one
  /// implementation.
  skipped,
}

/// The outcome of comparing every implementation's output to the
/// baseline's output.
final class VerificationResult<Input, Output> {
  final VerificationStatus status;
  final List<Mismatch<Input, Output>> mismatches;

  /// Number of test cases checked. Zero when [status] is skipped.
  final int caseCount;

  /// Number of implementations compared, including the baseline.
  final int implementationCount;

  VerificationResult({
    required List<Mismatch<Input, Output>> mismatches,
    required this.caseCount,
    required this.implementationCount,
  }) : status = mismatches.isEmpty
           ? VerificationStatus.passed
           : VerificationStatus.failed,
       mismatches = List.unmodifiable(mismatches);

  const VerificationResult.skipped({required this.implementationCount})
    : status = VerificationStatus.skipped,
      mismatches = const [],
      caseCount = 0;

  bool get passed => status == VerificationStatus.passed;
  bool get failed => status == VerificationStatus.failed;
}

/// Benchmark samples and statistics for one implementation.
///
/// Each sample is the time, in milliseconds, of one pass over all test
/// cases.
final class ImplResult {
  final String name;

  /// Samples in milliseconds, in the order they were measured.
  final List<double> samples;

  /// Samples in milliseconds, in ascending order.
  final List<double> sortedSamples;

  /// Number of test cases in each sample.
  final int casesPerSample;

  final double total;
  final double mean;

  /// Throws an [ArgumentError] if [samples] is empty or [casesPerSample]
  /// is less than 1.
  factory ImplResult({
    required String name,
    required List<double> samples,
    required int casesPerSample,
  }) {
    if (samples.isEmpty) {
      throw ArgumentError.value(samples, 'samples', 'Must not be empty');
    }
    if (casesPerSample < 1) {
      throw RangeError.value(casesPerSample, 'casesPerSample', 'Must be >= 1');
    }
    final total = samples.fold(0.0, (sum, sample) => sum + sample);
    return ImplResult._(
      name: name,
      samples: List.unmodifiable(samples),
      sortedSamples: List.unmodifiable(List.of(samples)..sort()),
      casesPerSample: casesPerSample,
      total: total,
      mean: total / samples.length,
    );
  }

  ImplResult._({
    required this.name,
    required this.samples,
    required this.sortedSamples,
    required this.casesPerSample,
    required this.total,
    required this.mean,
  });

  double get min => sortedSamples.first;
  double get max => sortedSamples.last;

  double get median {
    final sorted = sortedSamples;
    final mid = sorted.length ~/ 2;
    return sorted.length.isOdd
        ? sorted[mid]
        : (sorted[mid - 1] + sorted[mid]) / 2;
  }

  /// Sample standard deviation. [double.nan] for fewer than 2 samples.
  double get stdDev {
    if (samples.length < 2) return double.nan;
    final m = mean;
    final sumSquares = samples.fold(
      0.0,
      (sum, sample) => sum + (sample - m) * (sample - m),
    );
    return math.sqrt(sumSquares / (samples.length - 1));
  }

  /// Test cases completed per second, across all samples.
  /// [double.infinity] if [total] is zero.
  double get opsPerSecond => samples.length * casesPerSample / total * 1000;
}

/// Whether CPU profiling ran.
enum ProfileStatus {
  /// [PerfTester.run] was called with `profile: false`.
  notRequested,

  /// Profiling was requested, but the VM service was not available.
  /// See [PerfResult.profileUnavailableReason].
  unavailable,

  /// Profiles were captured. See [PerfResult.profiles].
  captured,
}

/// One function in a CPU profile.
final class ProfileEntry {
  /// Readable name, such as `MyClass.method` or `[Stub] Await`.
  final String name;

  /// The resolved URL of the function's script, or an empty string.
  final String url;

  /// Samples where this function was running.
  final int selfTicks;

  /// Samples where this function or something it called was running.
  final int inclusiveTicks;

  const ProfileEntry({
    required this.name,
    required this.url,
    required this.selfTicks,
    required this.inclusiveTicks,
  });
}

/// A DevTools CPU profile written to disk.
final class ProfileFile {
  final String path;
  final int frameCount;
  final int sampleCount;

  const ProfileFile({
    required this.path,
    required this.frameCount,
    required this.sampleCount,
  });
}

/// The CPU profile of one implementation.
final class ProfileResult {
  final String implementationName;

  /// Total samples in the profile. Zero if no samples were collected.
  final int sampleCount;

  /// Sampling interval in microseconds.
  final int samplePeriodMicros;

  /// The functions with the most self time, highest first. Functions with
  /// no ticks are left out.
  final List<ProfileEntry> topFunctions;

  /// The saved DevTools profile, or null if the profile was not saved.
  final ProfileFile? savedFile;

  ProfileResult({
    required this.implementationName,
    required this.sampleCount,
    required this.samplePeriodMicros,
    required List<ProfileEntry> topFunctions,
    this.savedFile,
  }) : topFunctions = List.unmodifiable(topFunctions);

  /// Percentage of samples in [ticks]. Zero if there are no samples.
  double percentOfSamples(int ticks) =>
      sampleCount == 0 ? 0 : ticks / sampleCount * 100;
}

/// Everything a [PerfTester.run] measured.
final class PerfResult<Input, Output> {
  final String testName;
  final int testCaseCount;
  final int warmupRuns;
  final int benchmarkRuns;

  /// One entry per implementation, in the order they were given. The first
  /// entry is the baseline.
  final List<ImplResult> implementations;

  final VerificationResult<Input, Output> verification;

  final ProfileStatus profileStatus;

  /// Why profiling did not run. Null unless [profileStatus] is
  /// [ProfileStatus.unavailable].
  final String? profileUnavailableReason;

  /// One entry per implementation when [profileStatus] is
  /// [ProfileStatus.captured]. Otherwise empty.
  final List<ProfileResult> profiles;

  PerfResult({
    required this.testName,
    required this.testCaseCount,
    required this.warmupRuns,
    required this.benchmarkRuns,
    required List<ImplResult> implementations,
    required this.verification,
    required this.profileStatus,
    this.profileUnavailableReason,
    List<ProfileResult> profiles = const [],
  }) : implementations = List.unmodifiable(implementations),
       profiles = List.unmodifiable(profiles);

  ImplResult get baseline => implementations.first;
}
