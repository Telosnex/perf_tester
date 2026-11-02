import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:isolate' as isolate;

import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

import 'results.dart';

/// Connects to the VM service running in *this* process and collects CPU
/// profiling samples around a user-supplied block.
///
/// Requires `--enable-vm-service` when launching:
/// ```bash
/// dart run --enable-vm-service test/perf/some_perf_test.dart
/// ```
///
/// If the VM service isn't available (e.g. normal `dart run` without the
/// flag), [connect] returns `false`, [unavailableReason] says why, and the
/// other methods are no-ops.
///
/// This class does not print. [PerfTester.run] passes its results to a
/// [PerfReporter].
class PerfProfiler {
  VmService? _service;
  String? _isolateId;
  CpuSamples? _captured;
  String? _unavailableReason;

  /// Why the last [connect] failed. Null if it succeeded or was not called.
  String? get unavailableReason => _unavailableReason;

  /// Try to connect to the VM service. Returns `true` on success.
  Future<bool> connect() async {
    _unavailableReason = null;
    try {
      // getInfo() reads existing state without blocking (controlWebServer
      // hangs in the Flutter tester even with --enable-vmservice).
      final info = await developer.Service.getInfo();
      final uri = info.serverUri;
      if (uri == null) {
        _unavailableReason = const bool.fromEnvironment('dart.vm.product')
            ? 'This build has no VM service (dart compile exe, or a Flutter '
                  'release build). Profile under the JIT, or in a Flutter '
                  'profile build.'
            : 'VM service not available. '
                  'Run with: dart run --enable-vm-service <script>';
        return false;
      }

      // Convert HTTP URI to WebSocket URI.
      final wsUri = uri.replace(
        scheme: uri.scheme == 'https' ? 'wss' : 'ws',
        path: '${uri.path}ws',
      );

      // Flutter test bindings replace HttpClient with a mock that returns
      // 400 for every request, so connect with the default HttpClient.
      _service =
          await HttpOverrides.runWithHttpOverrides(
            () => vmServiceConnectUri(wsUri.toString()),
            _DefaultHttpOverrides(),
          ).timeout(
            const Duration(seconds: 5),
            onTimeout: () => throw TimeoutException(
              'VM service connection timed out after 5s',
            ),
          );

      // Enable the profiler.
      await _service!.setFlag('profiler', 'true');

      // Get our own isolate ID.
      _isolateId = developer.Service.getIsolateId(isolate.Isolate.current);
      if (_isolateId == null) {
        await dispose();
        _unavailableReason = 'Could not determine isolate ID.';
        return false;
      }

      return true;
    } catch (e) {
      // An open connection keeps the process alive; close it if setFlag or
      // a later step failed after connecting.
      await dispose();
      _unavailableReason =
          Platform.isMacOS && e is SocketException && e.osError?.errorCode == 1
          ? 'The macOS app sandbox blocked the connection. Add '
                'com.apple.security.network.client to '
                'macos/Runner/DebugProfile.entitlements. ($e)'
          : 'Failed to connect: $e';
      return false;
    }
  }

  /// Clear previously collected CPU samples so the next [capture] only sees
  /// samples from the benchmark region.
  Future<void> clearSamples() async {
    if (_service == null || _isolateId == null) return;
    _captured = null;
    await _service!.clearCpuSamples(_isolateId!);
  }

  /// Fetch the samples accumulated since [clearSamples] **once**, caching them
  /// for [summarize] and [saveAsDevToolsJson].
  ///
  /// Both consumers must analyse the *same* snapshot. A `getCpuSamples`
  /// round-trip is itself expensive Dart work in this isolate — the VM
  /// resolves script/library metadata for every function, then encodes a
  /// multi-megabyte JSON response — and that work lands in this isolate's own
  /// sample buffer. So a second fetch ends up profiling the first fetch:
  /// before this snapshot was shared, the hottest leaves in the saved JSON
  /// were `dart::Library::LoadedScripts`, `dart::Script::FindLibrary` and the
  /// JSON parser (the profiler itself), while the printed table — fetched
  /// first, so unpolluted — told a completely different story.
  Future<CpuSamples?> capture() async {
    if (_service == null || _isolateId == null) return null;
    return _captured = await _service!.getCpuSamples(_isolateId!, 0, ~0);
  }

  /// Summarizes the captured samples: the [topN] functions with the most
  /// self time, highest first. Functions with no ticks are left out.
  ///
  /// Uses the snapshot from [capture], and calls [capture] if there is no
  /// snapshot yet. Returns null if not connected.
  Future<ProfileResult?> summarize({
    required String implementationName,
    int topN = 20,
    ProfileFile? savedFile,
  }) async {
    if (_service == null || _isolateId == null) return null;

    final cpuSamples = _captured ?? await capture();
    if (cpuSamples == null) return null;
    final functions = cpuSamples.functions ?? const <ProfileFunction>[];
    final samples = cpuSamples.samples ?? const <CpuSample>[];
    final period = cpuSamples.samplePeriod ?? 0; // microseconds

    if (samples.isEmpty) {
      return ProfileResult(
        implementationName: implementationName,
        sampleCount: 0,
        samplePeriodMicros: period,
        topFunctions: const [],
        savedFile: savedFile,
      );
    }

    // Sort by exclusive ticks (self time) descending.
    final sorted = List.of(
      functions,
    )..sort((a, b) => (b.exclusiveTicks ?? 0).compareTo(a.exclusiveTicks ?? 0));

    final top = <ProfileEntry>[];
    for (final pf in sorted) {
      if (top.length >= topN) break;
      final excl = pf.exclusiveTicks ?? 0;
      final incl = pf.inclusiveTicks ?? 0;
      if (excl == 0 && incl == 0) continue;
      top.add(
        ProfileEntry(
          name: _functionName(pf),
          url: pf.resolvedUrl ?? '',
          selfTicks: excl,
          inclusiveTicks: incl,
        ),
      );
    }

    return ProfileResult(
      implementationName: implementationName,
      sampleCount: cpuSamples.sampleCount ?? samples.length,
      samplePeriodMicros: period,
      topFunctions: top,
      savedFile: savedFile,
    );
  }

  /// Dump the currently collected CPU samples in DevTools'
  /// `cpu-profiler` JSON shape to [path], for loading into DevTools or an
  /// offline analysis script.
  ///
  /// Returns what was written, or null if not connected.
  ///
  /// The DevTools schema expects an interned stackFrame tree where each
  /// node carries `{name, resolvedUrl, packageUri?, parent?}` and each
  /// sample references its leaf via `sf`. We build that tree by walking
  /// each sample's stack root→leaf and interning on
  /// `(functionIndex, parentNodeId)` so shared prefixes fold together
  /// (which is what keeps the JSON small for long-running captures).
  ///
  /// Note: `sourceLine` is omitted — the VM service returns function
  /// metadata without locations unless we fetch each `Func` individually,
  /// which would balloon into thousands of extra RPC round-trips.
  Future<ProfileFile?> saveAsDevToolsJson(String path) async {
    final service = _service;
    final isolateId = _isolateId;
    if (service == null || isolateId == null) return null;

    final cs = _captured ?? await capture();
    if (cs == null) return null;
    final funcs = cs.functions ?? const <ProfileFunction>[];
    final samples = cs.samples ?? const <CpuSample>[];

    final stackFrames = <String, Map<String, Object?>>{};
    final intern = <String, String>{};
    var nextFrameId = 0;

    String internFrame(int funcIdx, String? parentId) {
      final key = '$funcIdx|${parentId ?? ''}';
      final existing = intern[key];
      if (existing != null) return existing;
      final id = 's${nextFrameId++}';
      intern[key] = id;

      final pf = funcs[funcIdx];
      final name = _functionName(pf);
      final url = pf.resolvedUrl ?? '';
      final frame = <String, Object?>{'name': name, 'resolvedUrl': url};
      // DevTools uses the resolved URL as packageUri for package:/dart:
      // URIs; analysis tools group frames by that field, so mirror the
      // behaviour here.
      if (url.startsWith('package:') || url.startsWith('dart:')) {
        frame['packageUri'] = url;
      }
      if (parentId != null) frame['parent'] = parentId;
      stackFrames[id] = frame;
      return id;
    }

    final traceEvents = <Map<String, Object?>>[];
    for (final s in samples) {
      final stack = s.stack ?? const <int>[];
      if (stack.isEmpty) continue;
      // CpuSample.stack is ordered leaf-first (index 0 = most recent
      // frame). Walk root→leaf so interning produces a tree whose
      // root has parent == null and the leaf — the reference we want
      // on `sf` — is what internFrame() last returned.
      String? parent;
      for (var i = stack.length - 1; i >= 0; i--) {
        parent = internFrame(stack[i], parent);
      }
      traceEvents.add({
        'sf': parent,
        'tid': s.tid ?? 0,
        'ts': s.timestamp ?? 0,
      });
    }

    final dump = <String, Object?>{
      'cpu-profiler': <String, Object?>{
        'sampleCount': cs.sampleCount ?? samples.length,
        'samplePeriod': cs.samplePeriod ?? 0,
        'stackDepth': cs.maxStackDepth ?? 0,
        'timeExtentMicros': cs.timeExtentMicros ?? 0,
        'stackFrames': stackFrames,
        'traceEvents': traceEvents,
      },
    };

    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(dump));
    return ProfileFile(
      path: path,
      frameCount: stackFrames.length,
      sampleCount: traceEvents.length,
    );
  }

  /// Disconnect from the VM service. Safe to call more than once, and safe
  /// to call when [connect] failed or was never called.
  Future<void> dispose() async {
    final service = _service;
    _service = null;
    _isolateId = null;
    _captured = null;
    if (service == null) return;
    try {
      await service.dispose();
    } catch (_) {
      // The connection is unusable either way; do not hide the caller's
      // original error behind a cleanup error.
    }
  }

  String _functionName(ProfileFunction pf) {
    final func = pf.function;
    if (func is FuncRef) {
      final owner = func.owner;
      if (owner is ClassRef) {
        return '${owner.name}.${func.name}';
      }
      return func.name ?? '?';
    }
    if (func is NativeFunction) {
      return func.name ?? '[native]';
    }
    // Fallback: try .name via dynamic, else toString.
    try {
      return (func).name as String;
    } catch (_) {
      return func.toString();
    }
  }
}

/// Uses the default [HttpClient], in place of any override in the zone.
class _DefaultHttpOverrides extends HttpOverrides {}
