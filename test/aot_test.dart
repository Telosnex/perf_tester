@Timeout(Duration(minutes: 5))
library;

import 'dart:io';

import 'package:perf_tester/perf_tester.dart';
import 'package:test/test.dart';

/// Runs bin/aot.dart from the package root.
Future<ProcessResult> runAot(List<String> args, {String? workingDirectory}) =>
    Process.run(Platform.resolvedExecutable, [
      'run',
      '${Directory.current.path}/bin/aot.dart',
      ...args,
    ], workingDirectory: workingDirectory ?? Directory.current.path);

void main() {
  group('compilation mode', () {
    test('dart test runs under the JIT', () {
      expect(currentCompilationMode, CompilationMode.jit);
    });

    test('results and the console say JIT', () async {
      final lines = <String>[];
      final result =
          await PerfTester<int, int>(
            testName: 'mode',
            testCases: [1],
            implementation1: (n) => n,
            implementation2: (n) => n,
          ).run(
            warmupRuns: 0,
            benchmarkRuns: 4,
            reporter: ConsoleReporter(printLine: lines.add),
          );
      expect(result.compilationMode, CompilationMode.jit);
      expect(
        lines,
        contains(' Compiled: JIT. Comparisons are not reliable; see the end.'),
      );
      expect(lines.where((l) => l.contains('⚠️  JIT')), hasLength(1));
    });

    test('an AOT plan prints no warning', () async {
      final lines = <String>[];
      final reporter = ConsoleReporter(printLine: lines.add)
        ..runStarted(
          PerfRunPlan(
            testName: 'aot',
            implementationNames: ['A', 'B'],
            testCaseCount: 1,
            warmupRuns: 0,
            benchmarkRuns: 4,
            phases: [PerfPhase.benchmark],
            compilationMode: CompilationMode.aot,
          ),
        );
      final a = ImplResult(name: 'A', samples: [1, 2, 3, 4], casesPerSample: 1);
      final b = ImplResult(name: 'B', samples: [5, 6, 7, 8], casesPerSample: 1);
      reporter.benchmarkFinished([a, b], [compare(a, b)]);
      expect(lines, contains(' Compiled: AOT'));
      expect(lines.where((l) => l.contains('JIT')), isEmpty);
    });
  });

  group('perf_tester:aot', () {
    late Directory dir;
    setUp(() {
      // Inside the package, so package:perf_tester and package:test resolve.
      dir = Directory('build/aot_test')..createSync(recursive: true);
      addTearDown(() => dir.deleteSync(recursive: true));
    });

    test('runs a script AOT with arguments and defines', () async {
      File('${dir.path}/script.dart').writeAsStringSync('''
import 'package:perf_tester/perf_tester.dart';
void main(List<String> args) => print(
    'mode=\${currentCompilationMode.name} args=\$args '
    'key=\${const String.fromEnvironment('KEY')}');
''');
      File(
        '${dir.path}/defines.env',
      ).writeAsStringSync('# comment\nKEY="quoted value"\n');
      final result = await runAot([
        '--dart-define-from-file=${dir.path}/defines.env',
        '${dir.path}/script.dart',
        '--',
        'a',
        'b',
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(result.stdout, contains('mode=aot args=[a, b] key=quoted value'));
      expect(result.stderr, contains('with dart compile exe'));
    });

    test('a test file exits nonzero when a test fails', () async {
      File('${dir.path}/fail_test.dart').writeAsStringSync('''
import 'package:test/test.dart';
void main() {
  test('passes', () {});
  test('fails', () => expect(1, 2));
}
''');
      final result = await runAot(['${dir.path}/fail_test.dart']);
      expect(result.exitCode, isNot(0));
      expect(result.stdout, contains('Some tests failed.'));
    });

    test('a build error is reported', () async {
      File('${dir.path}/broken.dart').writeAsStringSync('void main() { x; }');
      final result = await runAot(['--dart', '${dir.path}/broken.dart']);
      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('Build failed.'));
    });

    test('usage errors exit 64', () async {
      for (final args in [
        <String>[],
        ['--bogus', 'x.dart'],
        ['a.dart', 'b.dart'],
        ['--dart', '--flutter', 'a.dart'],
        ['-D', 'novalue', 'a.dart'],
      ]) {
        final result = await runAot(args);
        expect(result.exitCode, 64, reason: '$args');
        expect(result.stderr, contains('Usage:'), reason: '$args');
      }
    });

    test('a missing file fails', () async {
      final result = await runAot(['${dir.path}/missing.dart']);
      expect(result.exitCode, 1);
      expect(result.stderr, contains('File not found'));
    });
  });

  // Builds a Flutter desktop app, which takes about a minute. Run with:
  //   PERF_TESTER_FLUTTER=1 dart test test/aot_test.dart
  test(
    'Flutter test file with testWidgets and profiling runs AOT',
    () async {
      final project = Directory.systemTemp.createTempSync('perf_tester_aot_');
      addTearDown(() => project.deleteSync(recursive: true));
      final platform = Platform.isMacOS
          ? 'macos'
          : Platform.isLinux
          ? 'linux'
          : 'windows';
      final create = await Process.run('flutter', [
        'create',
        '--platforms=$platform',
        '--project-name=fixture',
        project.path,
      ], runInShell: Platform.isWindows);
      expect(create.exitCode, 0, reason: '${create.stderr}');
      final pub = await Process.run(
        'flutter',
        ['pub', 'add', 'dev:perf_tester:{"path":"${Directory.current.path}"}'],
        workingDirectory: project.path,
        runInShell: Platform.isWindows,
      );
      expect(pub.exitCode, 0, reason: '${pub.stderr}');
      if (Platform.isMacOS) {
        // The template app is sandboxed without outgoing connections, which
        // the profiler needs.
        final entitlements = File(
          '${project.path}/macos/Runner/DebugProfile.entitlements',
        );
        entitlements.writeAsStringSync(
          entitlements.readAsStringSync().replaceFirst(
            '<dict>',
            '<dict>\n\t<key>com.apple.security.network.client</key>\n\t<true/>',
          ),
        );
      }
      File('${project.path}/test/bench_test.dart').writeAsStringSync('''
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:perf_tester/perf_tester.dart';

double width(int n) => (TextPainter(
      text: TextSpan(text: 'x' * n),
      textDirection: TextDirection.ltr,
    )..layout()).width;

void main() {
  testWidgets('bench', (tester) async {
    final result = await PerfTester<int, double>(
      testName: 'paint',
      testCases: [5, 10],
      implementation1: width,
      implementation2: width,
    ).run(
      warmupRuns: 10,
      benchmarkRuns: 8,
      profile: true,
      profileRuns: 200,
      runAsync: tester.runAsync,
    );
    print('RESULT \${result.compilationMode.name} \${result.profileStatus.name}');
  });
}
''');
      final result = await runAot([
        'test/bench_test.dart',
      ], workingDirectory: project.path);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      expect(result.stdout, contains('RESULT aot captured'));
      expect(result.stdout, contains('All tests passed!'));
    },
    skip: Platform.environment['PERF_TESTER_FLUTTER'] == '1'
        ? false
        : 'Set PERF_TESTER_FLUTTER=1 to build a Flutter app.',
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
