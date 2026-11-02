/// How the running Dart code was compiled.
enum CompilationMode {
  /// Compiled while it runs: `dart run`, `dart test`, `flutter test`, and
  /// Flutter debug builds.
  ///
  /// Identical code can run up to 1.5x faster or slower than its copy,
  /// and the difference can change during a run. Timing comparisons of
  /// small, hot functions are not reliable.
  jit,

  /// Compiled ahead of time: `dart compile exe` and Flutter profile and
  /// release builds.
  aot,
}

/// The [CompilationMode] of this program.
///
/// `dart compile exe` and Flutter release builds define `dart.vm.product`.
/// Flutter profile builds define `dart.vm.profile`.
const CompilationMode currentCompilationMode =
    bool.fromEnvironment('dart.vm.product') ||
        bool.fromEnvironment('dart.vm.profile')
    ? CompilationMode.aot
    : CompilationMode.jit;
