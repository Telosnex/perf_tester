import 'dart:async';
import 'dart:math' as math;

import 'package:perf_tester/perf_tester.dart';
import 'package:test/test.dart';

/// Records the name of every event, plus a few payloads.
class RecordingReporter extends PerfReporter {
  final events = <String>[];
  PerfRunPlan? plan;
  final mismatches = <Mismatch<Object?, Object?>>[];
  PerfResult<Object?, Object?>? finished;

  @override
  void runStarted(PerfRunPlan plan) {
    this.plan = plan;
    events.add('runStarted');
  }

  @override
  void verifyStarted() => events.add('verifyStarted');

  @override
  void mismatchFound(Mismatch<Object?, Object?> mismatch) {
    mismatches.add(mismatch);
    events.add('mismatchFound');
  }

  @override
  void verifyFinished(VerificationResult<Object?, Object?> verification) =>
      events.add('verifyFinished');

  @override
  void warmupStarted(int runs) => events.add('warmupStarted');

  @override
  void warmupFinished(Duration elapsed) => events.add('warmupFinished');

  @override
  void benchmarkStarted(int runs, int testCaseCount) =>
      events.add('benchmarkStarted');

  @override
  void benchmarkProgress(int completedRuns, int totalRuns, Duration elapsed) =>
      events.add('benchmarkProgress $completedRuns/$totalRuns');

  @override
  void benchmarkFinished(List<ImplResult> implementations) =>
      events.add('benchmarkFinished');

  @override
  void profileUnavailable(String reason) => events.add('profileUnavailable');

  @override
  void profileStarted() => events.add('profileStarted');

  @override
  void profileCaptured(ProfileResult profile) => events.add('profileCaptured');

  @override
  void runFinished(PerfResult<Object?, Object?> result) {
    finished = result;
    events.add('runFinished');
  }
}

/// Counts how often the value is serialized or stringified.
class Tracked {
  static var serializations = 0;
  final int value;
  Tracked(this.value);

  Object toJson() {
    serializations++;
    return value;
  }

  @override
  String toString() {
    serializations++;
    return 'Tracked($value)';
  }
}

Future<List<String>> capturePrints(Future<void> Function() body) async {
  final lines = <String>[];
  await runZoned(
    body,
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) => lines.add(line),
    ),
  );
  return lines;
}

void main() {
  group('ImplResult', () {
    test('computes statistics from samples', () {
      final r = ImplResult(name: 'A', samples: [3, 1, 2, 4], casesPerSample: 2);
      expect(r.samples, [3, 1, 2, 4]);
      expect(r.sortedSamples, [1, 2, 3, 4]);
      expect(r.min, 1);
      expect(r.max, 4);
      expect(r.median, 2.5);
      expect(r.mean, 2.5);
      expect(r.total, 10);
      expect(r.stdDev, closeTo(math.sqrt(5 / 3), 1e-12));
      // 4 samples × 2 cases in 10 ms.
      expect(r.opsPerSecond, closeTo(800, 1e-9));
    });

    test('odd sample count uses the middle value as median', () {
      final r = ImplResult(name: 'A', samples: [5, 1, 3], casesPerSample: 1);
      expect(r.median, 3);
    });

    test('one sample has NaN standard deviation', () {
      final r = ImplResult(name: 'A', samples: [2], casesPerSample: 1);
      expect(r.stdDev, isNaN);
      expect(r.median, 2);
    });

    test('copies samples and cannot be modified', () {
      final source = [1.0, 2.0];
      final r = ImplResult(name: 'A', samples: source, casesPerSample: 1);
      source.add(100);
      expect(r.samples, [1, 2]);
      expect(() => r.samples.add(3), throwsUnsupportedError);
      expect(() => r.sortedSamples.add(3), throwsUnsupportedError);
    });

    test('rejects empty samples and bad case counts', () {
      expect(
        () => ImplResult(name: 'A', samples: [], casesPerSample: 1),
        throwsArgumentError,
      );
      expect(
        () => ImplResult(name: 'A', samples: [1], casesPerSample: 0),
        throwsRangeError,
      );
    });
  });

  group('PerfTester.run result', () {
    test('contains samples and settings for each implementation', () async {
      final tester = PerfTester<int, int>(
        testName: 'result',
        testCases: [1, 2, 3],
        implementation1: (n) => n * 2,
        implementation2: (n) async => n + n,
        impl1Name: 'Mul',
        impl2Name: 'Add',
      );
      final result = await tester.run(
        warmupRuns: 2,
        benchmarkRuns: 4,
        reporter: const SilentReporter(),
      );

      expect(result.testName, 'result');
      expect(result.testCaseCount, 3);
      expect(result.warmupRuns, 2);
      expect(result.benchmarkRuns, 4);
      expect(result.implementations.map((r) => r.name), ['Mul', 'Add']);
      expect(result.baseline.name, 'Mul');
      for (var k = 0; k < 2; k++) {
        final impl = result.implementations[k];
        expect(impl.samples, tester.implTimes[k]);
        expect(impl.casesPerSample, 3);
      }
      expect(result.verification.status, VerificationStatus.passed);
      expect(result.verification.caseCount, 3);
      expect(result.verification.implementationCount, 2);
      expect(result.profileStatus, ProfileStatus.notRequested);
      expect(result.profileUnavailableReason, isNull);
      expect(result.profiles, isEmpty);
    });

    test('a later run does not change an earlier result', () async {
      final tester = PerfTester<int, int>.multi(
        testName: 'stable',
        testCases: [1],
        implementations: [PerfImpl('A', (n) => n)],
      );
      final first = await tester.run(
        warmupRuns: 0,
        benchmarkRuns: 3,
        reporter: const SilentReporter(),
      );
      await tester.run(
        warmupRuns: 0,
        benchmarkRuns: 1,
        reporter: const SilentReporter(),
      );
      expect(first.baseline.samples, hasLength(3));
    });

    test('reports mismatches in the result', () async {
      final result = await PerfTester<int, int>.multi(
        testName: 'mismatch',
        testCases: [1, 2, 3],
        implementations: [
          PerfImpl('A', (n) => n),
          PerfImpl('B', (n) => n == 2 ? -1 : n),
          PerfImpl('C', (n) => n == 3 ? -3 : n),
        ],
      ).run(warmupRuns: 0, benchmarkRuns: 1, reporter: const SilentReporter());

      final verification = result.verification;
      expect(verification.status, VerificationStatus.failed);
      expect(verification.failed, isTrue);
      expect(verification.passed, isFalse);
      expect(
        [
          for (final m in verification.mismatches)
            (
              m.caseIndex,
              m.input,
              m.baselineName,
              m.baselineOutput,
              m.implementationName,
              m.implementationOutput,
            ),
        ],
        [(1, 2, 'A', 2, 'B', -1), (2, 3, 'A', 3, 'C', -3)],
      );
    });

    test('verification is skipped when turned off or with one impl', () async {
      final off =
          await PerfTester<int, int>(
            testName: 'off',
            testCases: [1],
            implementation1: (n) => n,
            implementation2: (n) => -n,
          ).run(
            warmupRuns: 0,
            benchmarkRuns: 1,
            skipEqualityCheck: true,
            reporter: const SilentReporter(),
          );
      expect(off.verification.status, VerificationStatus.skipped);
      expect(off.verification.mismatches, isEmpty);

      final single = await PerfTester<int, int>.multi(
        testName: 'single',
        testCases: [1],
        implementations: [PerfImpl('A', (n) => n)],
      ).run(warmupRuns: 0, benchmarkRuns: 1, reporter: const SilentReporter());
      expect(single.verification.status, VerificationStatus.skipped);
    });

    test('custom equality check does not serialize outputs', () async {
      Tracked.serializations = 0;
      final result = await PerfTester<int, Tracked>(
        testName: 'no encode',
        testCases: [1, 2],
        implementation1: Tracked.new,
        implementation2: Tracked.new,
        equalityCheck: (a, b) => a!.value == b!.value,
      ).run(warmupRuns: 0, benchmarkRuns: 1, reporter: const SilentReporter());
      expect(result.verification.passed, isTrue);
      expect(Tracked.serializations, 0);
    });

    test(
      'profiling without the VM service is reported as unavailable',
      () async {
        final reporter = RecordingReporter();
        final result =
            await PerfTester<int, int>.multi(
              testName: 'no vm service',
              testCases: [1],
              implementations: [PerfImpl('A', (n) => n)],
            ).run(
              warmupRuns: 0,
              benchmarkRuns: 1,
              profile: true,
              profileRuns: 1,
              reporter: reporter,
            );
        expect(result.profileStatus, ProfileStatus.unavailable);
        expect(result.profileUnavailableReason, contains('VM service'));
        expect(result.profiles, isEmpty);
        expect(reporter.events, contains('profileUnavailable'));
      },
      testOn: '!browser',
    );
  });

  group('reporters', () {
    test('events arrive in the documented order', () async {
      final reporter = RecordingReporter();
      final result = await PerfTester<int, int>(
        testName: 'events',
        testCases: [1, 2],
        implementation1: (n) => n,
        implementation2: (n) => n == 2 ? 0 : n,
      ).run(warmupRuns: 1, benchmarkRuns: 2, reporter: reporter);

      expect(reporter.events, [
        'runStarted',
        'verifyStarted',
        'mismatchFound',
        'verifyFinished',
        'warmupStarted',
        'warmupFinished',
        'benchmarkStarted',
        'benchmarkProgress 1/2',
        'benchmarkProgress 2/2',
        'benchmarkFinished',
        'runFinished',
      ]);
      expect(reporter.finished, same(result));
      expect(reporter.mismatches.single.caseIndex, 1);

      final plan = reporter.plan!;
      expect(plan.testName, 'events');
      expect(plan.implementationNames, ['Original', 'Optimized']);
      expect(plan.testCaseCount, 2);
      expect(plan.warmupRuns, 1);
      expect(plan.benchmarkRuns, 2);
      expect(plan.phases, [
        PerfPhase.verify,
        PerfPhase.warmup,
        PerfPhase.benchmark,
      ]);
    });

    test('an implementation that throws stops the events', () async {
      final reporter = RecordingReporter();
      var calls = 0;
      final run = PerfTester<int, int>.multi(
        testName: 'throws',
        testCases: [1],
        implementations: [
          PerfImpl('A', (n) {
            // Throw on the first benchmark call, after 1 warmup call.
            if (++calls > 1) throw StateError('boom');
            return n;
          }),
        ],
      ).run(warmupRuns: 1, benchmarkRuns: 2, reporter: reporter);
      await expectLater(run, throwsStateError);
      expect(reporter.events.last, 'benchmarkStarted');
    });

    test('SilentReporter prints nothing', () async {
      final lines = await capturePrints(
        () =>
            PerfTester<int, int>(
              testName: 'quiet',
              testCases: [1, 2],
              implementation1: (n) => n,
              implementation2: (n) => -n,
            ).run(
              warmupRuns: 1,
              benchmarkRuns: 3,
              profile: true,
              profileRuns: 1,
              reporter: const SilentReporter(),
            ),
      );
      expect(lines, isEmpty);
    });

    test('ConsoleReporter writes through printLine', () async {
      final written = <String>[];
      final printed = await capturePrints(
        () =>
            PerfTester<int, int>(
              testName: 'custom sink',
              testCases: [1],
              implementation1: (n) => n,
              implementation2: (n) => n,
            ).run(
              warmupRuns: 0,
              benchmarkRuns: 2,
              reporter: ConsoleReporter(printLine: written.add),
            ),
      );
      expect(printed, isEmpty);
      expect(written, contains(' PerfTester: custom sink'));
      expect(written.join('\n'), contains('Results:'));
    });

    test('one ConsoleReporter numbers steps from 1 on every run', () async {
      final written = <String>[];
      final reporter = ConsoleReporter(printLine: written.add);
      final tester = PerfTester<int, int>(
        testName: 'reuse',
        testCases: [1],
        implementation1: (n) => n,
        implementation2: (n) => n,
      );
      await tester.run(warmupRuns: 0, benchmarkRuns: 1, reporter: reporter);
      await tester.run(warmupRuns: 0, benchmarkRuns: 1, reporter: reporter);
      final steps = written.where((line) => line.startsWith('[')).toList();
      expect(steps.map((line) => line.substring(0, 5)), [
        '[1/3]',
        '[2/3]',
        '[3/3]',
        '[1/3]',
        '[2/3]',
        '[3/3]',
      ]);
    });
  });
}
