import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// Runs the fixture in a child process with the VM service enabled.
/// A leaked VM service connection keeps the child alive, so a timeout here
/// means cleanup failed.
Future<ProcessResult> runFixture(String mode, String outputDir) async {
  final sdkBin = File(Platform.resolvedExecutable).parent.uri;
  final jitService = File.fromUri(
    sdkBin.resolve('snapshots/dart_runtime_service_vm.dart.snapshot'),
  );
  final aotService = File.fromUri(
    sdkBin.resolve('snapshots/dart_runtime_service_vm_aot.dart.snapshot'),
  );
  // Dart 3.14's Windows ARM64 SDK ships the experimental AOT service but
  // omits its JIT counterpart. Use the VM's built-in service in that case,
  // so the end-to-end profiling tests still run on the native JIT runtime.
  final useBuiltInService =
      Platform.isWindows && !jitService.existsSync() && aotService.existsSync();
  final process = await Process.start(Platform.resolvedExecutable, [
    if (useBuiltInService) '--disable-experimental-vm-service',
    'run',
    '--enable-vm-service=0',
    '--disable-service-auth-codes',
    'test/fixtures/profile_fixture.dart',
    mode,
    outputDir,
  ]);
  final stdoutFuture = process.stdout.transform(utf8.decoder).join();
  final stderrFuture = process.stderr.transform(utf8.decoder).join();
  final exitCode = await process.exitCode.timeout(
    const Duration(seconds: 30),
    onTimeout: () {
      process.kill();
      fail('Fixture "$mode" did not exit; VM service connection leaked?');
    },
  );
  return ProcessResult(
    process.pid,
    exitCode,
    await stdoutFuture,
    await stderrFuture,
  );
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('perf_tester_profile_');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  test(
    'process exits when an implementation throws during profiling',
    () async {
      final result = await runFixture('throw', tempDir.path);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(result.stdout, contains('FIXTURE_CAUGHT: boom'));
      expect(result.stdout, contains('FIXTURE_DONE'));
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test('saves one profile per implementation without collisions', () async {
    final result = await runFixture('save', tempDir.path);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(result.stdout, isNot(contains('Calling Service.getInfo')));
    expect(result.stdout, isNot(contains('getInfo returned')));

    final names =
        tempDir
            .listSync()
            .map((entity) => entity.uri.pathSegments.last)
            .toList()
          ..sort();
    expect(names, [
      'cpu_profile_Fixture_test__A_B.json',
      'cpu_profile_Fixture_test__A_B_2.json',
    ]);
    for (final name in names) {
      final json =
          jsonDecode(File('${tempDir.path}/$name').readAsStringSync())
              as Map<String, Object?>;
      expect(json, contains('cpu-profiler'));
    }

    expect(result.stdout, contains('FIXTURE_STATUS: captured'));
    expect(
      LineSplitter.split(
        result.stdout as String,
      ).where((line) => line.startsWith('FIXTURE_PROFILE: ')),
      [
        'FIXTURE_PROFILE: A B|cpu_profile_Fixture_test__A_B.json'
            '|samples=true|saved=true|top=3',
        'FIXTURE_PROFILE: A_B|cpu_profile_Fixture_test__A_B_2.json'
            '|samples=true|saved=true|top=3',
      ],
    );
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('SilentReporter prints nothing while profiling', () async {
    final result = await runFixture('silent', tempDir.path);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    // The VM prints its own service banner; everything else must come from
    // the fixture.
    final lines = LineSplitter.split(
      result.stdout as String,
    ).where((line) => line.isNotEmpty && !line.startsWith('The Dart '));
    expect(lines, everyElement(startsWith('FIXTURE_')));
    expect(lines, contains('FIXTURE_STATUS: captured'));
    expect(lines, contains('FIXTURE_DONE'));
  }, timeout: const Timeout(Duration(seconds: 60)));
}
