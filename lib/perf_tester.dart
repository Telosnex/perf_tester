/// Implementation comparison and CPU profiling for the Dart VM.
///
/// Each timing sample measures whole passes over all test cases. Fast
/// implementations get several passes per sample, so each sample takes at
/// least `minSampleTime`. Each implementation is compared to the first with
/// a Mann-Whitney U test, which can report no significant difference.
///
/// [PerfTester.run] returns a [PerfResult] with the raw samples, statistics,
/// verification outcome, and CPU profiles. Output mismatches do not throw;
/// check [PerfResult.verification]. Supply equalityCheck for values that
/// need custom comparison.
///
/// Progress goes to a [PerfReporter]. The default [ConsoleReporter] prints
/// text; [SilentReporter] prints nothing.
library;

export 'src/console_reporter.dart' show ConsoleReporter;
export 'src/perf_profiler.dart' show PerfProfiler;
export 'src/perf_tester.dart' show PerfImpl, PerfTester, profileFileNames;
export 'src/reporter.dart' show PerfReporter, SilentReporter;
export 'src/stats.dart'
    show
        MannWhitneyResult,
        compare,
        mannWhitneyU,
        minimumPValue,
        minimumSamplesFor;
export 'src/results.dart'
    show
        Comparison,
        ComparisonVerdict,
        ImplResult,
        Mismatch,
        PerfPhase,
        PerfResult,
        PerfRunPlan,
        ProfileEntry,
        ProfileFile,
        ProfileResult,
        ProfileStatus,
        VerificationResult,
        VerificationStatus;
