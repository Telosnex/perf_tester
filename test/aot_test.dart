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
        ['--dart', '--flutter', 'a.dart'],
        ['-D', 'novalue', 'a.dart'],
      ]) {
        final result = await runAot(args);
        expect(result.exitCode, 64, reason: '$args');
        expect(result.stderr, contains('Usage:'), reason: '$args');
      }
    });

    test('several files share one build, one process each', () async {
      final sub = Directory('${dir.path}/sub')..createSync();
      // Each file increments the same global. A count of 1 in both shows
      // that state from one file does not reach the next.
      File('${dir.path}/counter.dart').writeAsStringSync('int count = 0;');
      File('${dir.path}/a_test.dart').writeAsStringSync('''
import 'package:test/test.dart';
import 'counter.dart';
void main() => test('a', () => print(
    'A count=\${++count} aot=\${const bool.fromEnvironment('dart.vm.product')}'));
''');
      File('${sub.path}/b_test.dart').writeAsStringSync('''
import 'package:test/test.dart';
import '../counter.dart';
Future<void> main() async {
  await Future<void>.delayed(Duration.zero);
  test('b', () => print('B count=\${++count}'));
}
''');
      File('${sub.path}/helper.dart').writeAsStringSync('void main() {}');
      final result = await runAot([dir.path]);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      expect(result.stderr, contains('Building 2 files'));
      expect(result.stderr, contains('Running 1/2 (AOT): build/aot_test/a_'));
      expect(result.stderr, contains('Running 2/2 (AOT): build/aot_test/sub'));
      expect(result.stderr, contains('2 of 2 files passed.'));
      expect(result.stdout, contains('A count=1 aot=true'));
      expect(result.stdout, contains('B count=1'));
      expect(
        Directory('build/perf_tester_aot').listSync().map((e) => e.path),
        isNot(contains(endsWith('.dart'))),
      );
    });

    test('a failure in one of several files fails the run', () async {
      File('${dir.path}/ok_test.dart').writeAsStringSync('''
import 'package:test/test.dart';
void main() => test('ok', () {});
''');
      File('${dir.path}/bad_test.dart').writeAsStringSync('''
import 'package:test/test.dart';
void main() => test('bad', () => expect(1, 2));
''');
      File(
        '${dir.path}/script.dart',
      ).writeAsStringSync("void main() => print('SCRIPT ran');");
      final result = await runAot([
        '${dir.path}/bad_test.dart',
        '${dir.path}/ok_test.dart',
        '${dir.path}/script.dart',
      ]);
      expect(result.exitCode, 1);
      expect(result.stdout, contains('Some tests failed.'));
      expect(result.stdout, contains('SCRIPT ran'));
      expect(result.stderr, contains('2 of 3 files passed.'));
      expect(result.stderr, contains('Failed: build/aot_test/bad_test.dart'));
    });

    test('arguments need a single file', () async {
      File('${dir.path}/a.dart').writeAsStringSync('void main() {}');
      File('${dir.path}/b.dart').writeAsStringSync('void main() {}');
      final result = await runAot([
        '${dir.path}/a.dart',
        '${dir.path}/b.dart',
        '--',
        'x',
      ]);
      expect(result.exitCode, 1);
      expect(result.stderr, contains('work only with one file'));
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
    'Flutter test files with testWidgets and profiling run AOT',
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
        [
          'pub',
          'add',
          'dev:perf_tester:{"path":"${Directory.current.path}"}',
          'dev:test',
        ],
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
      // Both files run inside flutter_test_config.dart, as with flutter test.
      File('${project.path}/test/plain_test.dart').writeAsStringSync('''
import 'dart:async';
import 'package:test/test.dart';
void main() => test('plain', () => print('PLAIN \${Zone.current[#config]}'));
''');
      File('${project.path}/test/flutter_test_config.dart').writeAsStringSync(
        '''
import 'dart:async';
Future<void> testExecutable(FutureOr<void> Function() testMain) =>
    runZoned(() async => testMain(), zoneValues: {#config: 'configured'});
''',
      );
      File('${project.path}/test/widget_test.dart').deleteSync();
      final result = await runAot(['test'], workingDirectory: project.path);
      final out = '${result.stdout}';
      expect(result.exitCode, 0, reason: '$out${result.stderr}');
      expect(result.stderr, contains('Building 2 files as a Flutter'));
      expect(result.stderr, contains('2 of 2 files passed.'));
      expect(out, contains('RESULT aot captured'));
      expect(out, contains('PLAIN configured'));
    },
    skip: Platform.environment['PERF_TESTER_FLUTTER'] == '1'
        ? false
        : 'Set PERF_TESTER_FLUTTER=1 to build a Flutter app.',
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
