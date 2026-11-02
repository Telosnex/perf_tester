/// Implementation comparison and CPU profiling for the Dart VM.
///
/// Each timing sample measures one pass over all test cases. Synchronous
/// functions also use the asynchronous invocation path, so harness overhead
/// can dominate very short operations.
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
export 'src/results.dart'
    show
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
