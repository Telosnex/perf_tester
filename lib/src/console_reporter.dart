import 'dart:math' as math;

import 'compilation_mode.dart';
import 'encode.dart';
import 'reporter.dart';
import 'results.dart';
import 'stats.dart';

/// A [PerfReporter] that prints progress, a results table, timing
/// histograms, and CPU profiles as text.
///
/// This is the default reporter for [PerfTester.run]. One instance can be
/// used for several runs, but not for runs that overlap.
class ConsoleReporter extends PerfReporter {
  /// Prints every line through [printLine], which defaults to [print].
  ConsoleReporter({void Function(String line)? printLine})
    : _print = printLine ?? print;

  final void Function(String line) _print;

  int _step = 0;
  int _totalSteps = 0;
  List<String> _names = const [];
  CompilationMode _mode = currentCompilationMode;

  static const _ruleDouble =
      '══════════════════════════════════════════════════════';
  static const _ruleSingle =
      '──────────────────────────────────────────────────────';

  void _stepLine(String msg) {
    _step++;
    _print('');
    _print('[$_step/$_totalSteps] $msg');
  }

  void _sub(String msg) => _print('      $msg');

  static String _plural(int count, String noun) =>
      '$count $noun${count == 1 ? '' : 's'}';

  // ── Progress ──────────────────────────────────────────────────────────

  @override
  void runStarted(PerfRunPlan plan) {
    _step = 0;
    _totalSteps = plan.phases.length;
    _names = plan.implementationNames;
    _mode = plan.compilationMode;

    _print('');
    _print(_ruleDouble);
    _print(' PerfTester: ${plan.testName}');
    _print(_ruleDouble);
    final steps = [
      for (final phase in plan.phases)
        switch (phase) {
          PerfPhase.verify => 'Verify',
          PerfPhase.warmup => 'Warmup',
          PerfPhase.benchmark => 'Benchmark',
          PerfPhase.profile => 'Profile (×${_names.length})',
        },
    ];
    _print(' Implementations: ${_names.join(', ')}');
    _print(' Steps: ${steps.join(' → ')}');
    _print(switch (_mode) {
      CompilationMode.aot => ' Compiled: AOT',
      CompilationMode.jit =>
        ' Compiled: JIT. Comparisons are not reliable; see the end.',
    });
    _print(_ruleSingle);
  }

  @override
  void verifyStarted() {
    _stepLine(
      'Verify: checking all implementations produce identical output...',
    );
  }

  @override
  void mismatchFound(Mismatch<Object?, Object?> mismatch) {
    final baseEncoded = safeEncode(mismatch.baselineOutput);
    final encoded = safeEncode(mismatch.implementationOutput);
    _sub(
      '❌ Mismatch on test case ${mismatch.caseIndex}: '
      '${mismatch.baselineName} vs ${mismatch.implementationName}',
    );
    _sub('Input: ${mismatch.input}');

    if (baseEncoded.length > 1000 || encoded.length > 1000) {
      _printStringDiff(
        baseEncoded,
        encoded,
        labelA: mismatch.baselineName,
        labelB: mismatch.implementationName,
      );
    } else {
      _sub('${mismatch.baselineName}: $baseEncoded');
      _sub('${mismatch.implementationName}: $encoded');
    }
  }

  @override
  void verifyFinished(VerificationResult<Object?, Object?> verification) {
    if (verification.passed) {
      _sub(
        '✅ All ${_plural(verification.caseCount, 'test case')} match across '
        '${verification.implementationCount} implementations.',
      );
    } else if (verification.failed) {
      _sub('❌ Differences found in outputs!');
    }
  }

  @override
  void warmupStarted(int runs) {
    _stepLine('Warmup: ${_plural(runs, 'randomly selected test case')}...');
  }

  @override
  void warmupFinished(Duration elapsed) {
    _sub('Done (${elapsed.inMilliseconds} ms).');
  }

  @override
  void benchmarkStarted(int runs, int testCaseCount) {
    _stepLine(
      'Benchmark: ${_plural(runs, 'run')}, '
      '${_plural(testCaseCount, 'test case')} each...',
    );
  }

  @override
  void benchmarkProgress(int completedRuns, int totalRuns, Duration elapsed) {
    // Print at most 10 progress messages.
    final printStep = math.max(1, totalRuns ~/ 10);
    if (completedRuns % printStep == 0 || completedRuns == totalRuns) {
      _sub('Run $completedRuns/$totalRuns (${elapsed.inMilliseconds} ms).');
    }
  }

  @override
  void benchmarkFinished(
    List<ImplResult> implementations,
    List<Comparison> comparisons,
  ) {
    _printPasses(implementations);
    _printStats(implementations);
    _printComparisons(comparisons);
    _printVisualizations(implementations);
  }

  /// Says how many passes each sample timed, if any sample timed more
  /// than one.
  void _printPasses(List<ImplResult> impls) {
    if (impls.every((impl) => impl.passesPerSample == 1)) return;
    _sub(
      'Passes per sample: '
      '${impls.map((impl) => '${impl.name} ${impl.passesPerSample}').join(', ')}'
      ' (times are per pass).',
    );
  }

  // ── Comparisons ───────────────────────────────────────────────────────

  void _printComparisons(List<Comparison> comparisons) {
    if (comparisons.isEmpty) return;
    final level = comparisons.first.significanceLevel;
    _print('');
    _sub('Comparison (Mann-Whitney U, two-sided, α = $level):');
    for (final c in comparisons) {
      final prefix = '${c.implementationName} vs ${c.baselineName}: ';
      _sub(switch (c.verdict) {
        ComparisonVerdict.faster =>
          '$prefix${_ratio(c.speedup)}x faster (median), ${_p(c.pValue)}',
        ComparisonVerdict.slower =>
          '$prefix${_ratio(1 / c.speedup)}x slower (median), ${_p(c.pValue)}',
        ComparisonVerdict.noSignificantDifference =>
          '${prefix}no significant difference, ${_p(c.pValue)}',
        ComparisonVerdict.tooFewSamples =>
          '${prefix}too few benchmark runs to compare '
              '(need at least ${minimumSamplesFor(c.significanceLevel)})',
      });
    }
    if (_mode == CompilationMode.jit) {
      _sub(
        '⚠️  JIT: identical code can differ by up to 1.5x, so these '
        'verdicts can be wrong.',
      );
      _sub('   Confirm with an AOT build: dart run perf_tester:aot <file>');
    }
  }

  static String _ratio(double value) =>
      value.isFinite ? value.toStringAsFixed(2) : 'n/a';

  static String _p(double p) =>
      p < 0.001 ? 'p < 0.001' : 'p = ${p.toStringAsFixed(3)}';

  @override
  void profileUnavailable(String reason) {
    _print('[PerfProfiler] $reason');
    _stepLine('Profile: skipped (VM service not available).');
  }

  @override
  void profileStarted() {
    _stepLine('Profile: running each implementation separately...');
  }

  @override
  void profileCaptured(ProfileResult profile) {
    _printProfile(profile);
    final file = profile.savedFile;
    if (file != null) {
      _print(
        '[PerfProfiler] Wrote DevTools profile: ${file.path} '
        '(${file.frameCount} frames, ${file.sampleCount} samples)',
      );
    }
  }

  // ── Results table ─────────────────────────────────────────────────────

  /// Prints aggregate statistics for all implementations, comparing each
  /// against the baseline (first implementation).
  void _printStats(List<ImplResult> impls) {
    final n = impls.length;

    // Helper function to format numbers intelligently
    String formatNumber(double value) {
      if (!value.isFinite) {
        return 'n/a';
      } else if (value >= 1000000) {
        return '${(value / 1000000).toStringAsFixed(2)}M';
      } else if (value >= 1000) {
        return '${(value / 1000).toStringAsFixed(2)}K';
      } else if (value >= 100) {
        return value.toStringAsFixed(1);
      } else if (value >= 10) {
        return value.toStringAsFixed(2);
      } else {
        return value.toStringAsFixed(3);
      }
    }

    final totals = [for (final impl in impls) impl.total];
    final opsPerSecs = [for (final impl in impls) impl.opsPerSecond];
    final mins = [for (final impl in impls) impl.min];
    final maxes = [for (final impl in impls) impl.max];
    final medians = [for (final impl in impls) impl.median];
    final means = [for (final impl in impls) impl.mean];
    final stdDevs = [for (final impl in impls) impl.stdDev];

    // Metrics: label → values per implementation
    final metrics = {
      'Total Time (ms)': totals,
      'Ops/Second': opsPerSecs,
      'Min (ms)': mins,
      'Max (ms)': maxes,
      'Median (ms)': medians,
      'Mean (ms)': means,
      'Std Dev (ms)': stdDevs,
    };

    final names = [for (final impl in impls) impl.name];

    final maxLabelWidth =
        metrics.keys.map((label) => label.length).reduce(math.max) + 2;

    // Column widths per implementation.
    final colWidths = <int>[];
    for (var k = 0; k < n; k++) {
      var maxW = names[k].length;
      for (final vals in metrics.values) {
        final v = vals[k];
        final formatted = v >= 1000 || !v.isFinite
            ? formatNumber(v)
            : v.toStringAsFixed(3);
        if (formatted.length > maxW) maxW = formatted.length;
      }
      colWidths.add(maxW + 2);
    }

    _print('');
    _sub('Results:');

    // Header row.
    final headerBuf = StringBuffer(''.padRight(maxLabelWidth));
    for (var k = 0; k < n; k++) {
      headerBuf.write(names[k].padRight(colWidths[k]));
    }
    if (n > 1) headerBuf.write('vs ${names[0]}');
    _sub(headerBuf.toString());

    // Row printer.
    void printRow(
      String label,
      List<double> vals, {
      bool formatLarge = false,
      bool higherIsBetter = false,
    }) {
      final buf = StringBuffer(label.padRight(maxLabelWidth));
      for (var k = 0; k < n; k++) {
        final formatted = formatLarge || !vals[k].isFinite
            ? formatNumber(vals[k])
            : vals[k].toStringAsFixed(3);
        buf.write(formatted.padRight(colWidths[k]));
      }

      // Comparison: each non-baseline vs baseline.
      final comparisons = <String>[];
      for (var k = 1; k < n; k++) {
        final baseVal = vals[0];
        final implVal = vals[k];

        // A ratio needs two finite, nonzero values.
        if (!baseVal.isFinite ||
            !implVal.isFinite ||
            baseVal == 0 ||
            implVal == 0) {
          comparisons.add('${names[k]}: n/a');
          continue;
        }

        var improvement = ((baseVal - implVal) / baseVal * 100);
        var speedupFactor = baseVal / implVal;

        if (higherIsBetter) {
          improvement = -improvement;
          speedupFactor = 1 / speedupFactor;
        }

        String comp;
        if (improvement > 0) {
          String speedupStr = speedupFactor.isInfinite
              ? 'Infinity'
              : speedupFactor.toStringAsFixed(1);
          comp = '↑${improvement.toStringAsFixed(1)}% (${speedupStr}x faster)';
        } else if (improvement < 0) {
          comp =
              '↓${(-improvement).toStringAsFixed(1)}% (${(1 / speedupFactor).toStringAsFixed(1)}x slower)';
        } else {
          comp = 'No difference';
        }
        comparisons.add('${names[k]}: $comp');
      }
      buf.write(comparisons.join('  '));
      _sub(buf.toString());
    }

    printRow('Total Time (ms):', totals);
    printRow(
      'Ops/Second:',
      opsPerSecs,
      formatLarge: true,
      higherIsBetter: true,
    );
    printRow('Min (ms):', mins);
    printRow('Max (ms):', maxes);
    printRow('Median (ms):', medians);
    printRow('Mean (ms):', means);
    printRow('Std Dev (ms):', stdDevs);
  }

  // ── Histograms ────────────────────────────────────────────────────────

  /// Prints histogram-style timing visualizations for all implementations.
  void _printVisualizations(List<ImplResult> impls) {
    // With a single sample (or identical samples) there is no range to bin;
    // binSize would be 0 and produce NaN.
    final totalSamples = impls.fold(0, (a, impl) => a + impl.samples.length);
    if (totalSamples < 2) return;

    final allSorted = [for (final impl in impls) impl.sortedSamples];

    var visMin = allSorted.map((s) => s.first).reduce(math.min);
    var visMax =
        allSorted.map((s) => s[(s.length * 0.99).floor()]).reduce(math.max) *
        1.2;
    final absMax = allSorted.map((s) => s.last).reduce(math.max);
    if (visMax > absMax) visMax = absMax;

    final binCount = 30;
    final binSize = (visMax - visMin) / binCount;
    if (binSize <= 0 || !binSize.isFinite) return;

    String formatValue(double val) {
      if (val < 0.001) return val.toStringAsFixed(6);
      if (val < 0.01) return val.toStringAsFixed(4);
      if (val < 0.1) return val.toStringAsFixed(3);
      if (val < 1) return val.toStringAsFixed(2);
      return val.toStringAsFixed(1);
    }

    // Build all histograms first to find global max count.
    final histograms = <List<int>>[];
    final outlierCounts = <int>[];
    for (final impl in impls) {
      final hist = List.filled(binCount, 0);
      var outliers = 0;
      for (var value in impl.samples) {
        if (value > visMax) {
          outliers++;
          continue;
        }
        var bin = ((value - visMin) / binSize).floor();
        bin = math.min(math.max(bin, 0), binCount - 1);
        hist[bin]++;
      }
      histograms.add(hist);
      outlierCounts.add(outliers);
    }

    var maxCount = 0;
    for (final hist in histograms) {
      final m = hist.reduce(math.max);
      if (m > maxCount) maxCount = m;
    }

    // Pad label to the longest implementation name (min 15).
    final maxNameLen = impls.map((e) => e.name.length).reduce(math.max);
    final labelWidth = math.max(15, maxNameLen + 1);

    String getDistributionLine(
      List<int> hist,
      String label,
      int outlierCount,
      double min,
      double max,
    ) {
      var line = StringBuffer();
      line.write('${label.padRight(labelWidth)}│');

      // Use square root scaling for better visibility
      for (var count in hist) {
        var heightRatio = count == 0
            ? 0
            : math.sqrt(count) / math.sqrt(maxCount);
        var height = (heightRatio * 8).round();
        var char = switch (height) {
          0 => ' ',
          1 => '▁',
          2 => '▂',
          3 => '▃',
          4 => '▄',
          5 => '▅',
          6 => '▆',
          7 => '▇',
          _ => '█',
        };
        line.write(char);
      }
      line.write('│');

      // Add statistics
      line.write(' n=${hist.reduce((a, b) => a + b)}');
      if (outlierCount > 0) line.write(' (+$outlierCount)');
      line.write(' [${formatValue(min)}-${formatValue(max)}ms]');

      return line.toString();
    }

    _print('');
    _sub(
      'Distribution (showing ${formatValue(visMin)}-${formatValue(visMax)}ms):',
    );
    for (var k = 0; k < impls.length; k++) {
      _sub(
        getDistributionLine(
          histograms[k],
          impls[k].name,
          outlierCounts[k],
          impls[k].min,
          impls[k].max,
        ),
      );
    }
  }

  // ── CPU profile ───────────────────────────────────────────────────────

  void _printProfile(ProfileResult profile) {
    if (profile.sampleCount == 0) {
      _print('\n[PerfProfiler] No CPU samples collected.');
      return;
    }

    final title =
        'CPU Profile: ${profile.implementationName}  '
        '(${profile.sampleCount} samples, ${profile.samplePeriodMicros}µs)';
    final boxWidth = title.length + 4;
    _print('');
    _print('      ┌${'─' * boxWidth}┐');
    _print('      │  $title  │');
    _print('      └${'─' * boxWidth}┘');
    _print(
      '      Self% = time in function itself.  '
      'Incl% = time in function + everything it calls.',
    );
    _print(
      '      [Stub] = compiler-generated helpers '
      '(type checks, allocation, etc.).',
    );
    _print('');
    _print(
      '      ${'Self%'.padRight(8)}'
      '${'Incl%'.padRight(8)}'
      '${'Self'.padRight(8)}'
      '${'Incl'.padRight(8)}'
      'Function',
    );
    _print('      ${'─' * 8}${'─' * 8}${'─' * 8}${'─' * 8}${'─' * 40}');

    for (final entry in profile.topFunctions) {
      final exclPct = profile
          .percentOfSamples(entry.selfTicks)
          .toStringAsFixed(1);
      final inclPct = profile
          .percentOfSamples(entry.inclusiveTicks)
          .toStringAsFixed(1);
      final url = entry.url;
      // Shorten the URL to just the filename.
      final shortUrl = url.contains('/') ? url.split('/').last : url;

      _print(
        '      ${exclPct.padLeft(5)}%  '
        '${inclPct.padLeft(5)}%  '
        '${entry.selfTicks.toString().padLeft(6)}  '
        '${entry.inclusiveTicks.toString().padLeft(6)}  '
        '${entry.name} ($shortUrl)',
      );
    }
  }

  // ── Long mismatch diff ────────────────────────────────────────────────

  /// Prints a compact diff between two long strings by showing the common
  /// prefix/suffix and the differing middle segments with context.
  void _printStringDiff(
    String a,
    String b, {
    required String labelA,
    required String labelB,
  }) {
    const context = 200;
    const maxMiddle = 600;

    // Find common prefix
    final minLen = a.length < b.length ? a.length : b.length;
    var prefix = 0;
    while (prefix < minLen && a.codeUnitAt(prefix) == b.codeUnitAt(prefix)) {
      prefix++;
    }

    // Find common suffix without overlapping the prefix
    var suffix = 0;
    while (suffix < minLen - prefix &&
        a.codeUnitAt(a.length - 1 - suffix) ==
            b.codeUnitAt(b.length - 1 - suffix)) {
      suffix++;
    }

    final aMidStart = prefix;
    final aMidEnd = a.length - suffix;
    final bMidStart = prefix;
    final bMidEnd = b.length - suffix;

    String safeSlice(String s, int start, int end) {
      if (start < 0) start = 0;
      if (end > s.length) end = s.length;
      if (start > end) start = end;
      return s.substring(start, end);
    }

    // Limit middle segments to maxMiddle each for readability
    final aMid = safeSlice(
      a,
      aMidStart,
      (aMidStart + maxMiddle).clamp(0, aMidEnd),
    );
    final bMid = safeSlice(
      b,
      bMidStart,
      (bMidStart + maxMiddle).clamp(0, bMidEnd),
    );

    // Metadata
    _print('--- Diff summary ---');
    _print('Lengths: $labelA=${a.length}, $labelB=${b.length}');
    _print('Common prefix: $prefix chars, Common suffix: $suffix chars');

    // Show diff with context
    if (prefix > 0) {
      final prefixSnippet = safeSlice(
        a,
        (prefix - context).clamp(0, a.length),
        prefix,
      );

      _print('...${prefixSnippet.replaceAll('\n', '\\n')}');
    }
    _print('<<< $labelA differs >>>');
    _print(aMid.replaceAll('\n', '\\n'));
    _print('>>> $labelB differs <<<');
    _print(bMid.replaceAll('\n', '\\n'));
    if (suffix > 0) {
      final hasSuffixEllipsis = suffix > context;

      final suffixSnippet = safeSlice(
        a,
        a.length - suffix,
        (a.length - suffix + context).clamp(0, a.length),
      );
      _print(
        '${suffixSnippet.replaceAll('\n', '\\n')}${hasSuffixEllipsis ? '...' : ''}',
      );
    }
    _print('--- End diff ---');
  }
}
