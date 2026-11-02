import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// Runs the fixture in a child process with the VM service enabled.
/// A leaked VM service connection keeps the child alive, so a timeout here
/// means cleanup failed.
Future<ProcessResult> runFixture(String mode, String outputDir) async {
  final process = await Process.start(Platform.resolvedExecutable, [
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
  }, timeout: const Timeout(Duration(seconds: 60)));
}
