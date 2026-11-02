/// Implementation comparison and CPU profiling for the Dart VM.
///
/// Each timing sample measures one pass over all test cases. Synchronous
/// functions also use the asynchronous invocation path, so harness overhead
/// can dominate very short operations. Output mismatches are printed and do
/// not throw. Supply equalityCheck for values that need custom comparison.
library;

export 'src/perf_tester.dart' show PerfImpl, PerfTester, profileFileNames;
export 'src/perf_profiler.dart' show PerfProfiler;
