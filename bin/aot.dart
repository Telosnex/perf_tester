// Runs benchmark files compiled ahead of time (AOT), so timing comparisons
// are not affected by the JIT.
//
//   dart run perf_tester:aot [options] <file or directory>... [-- args...]
//
// Pure Dart files are built with `dart compile exe`. Files that need
// Flutter are built as a Flutter profile app for this computer. A file can
// be a script with `main`, or a test file that uses package:test or
// package:flutter_test, `testWidgets` included.
//
// Several files are built into one program, then the program runs once per
// file. Each file gets a new process, as each gets a new isolate with
// `flutter test`, so state from one file does not reach the next.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// The environment variable that tells the program which file to run.
const _targetVariable = 'PERF_TESTER_AOT_TARGET';

const _usage = '''
Runs Dart or Flutter benchmark files compiled ahead of time (AOT).

Usage: dart run perf_tester:aot [options] <path>... [-- args...]

  <path>        A script with main(), a test file (package:test or
                package:flutter_test, testWidgets included), or a directory.
                A directory gives all *_test.dart files below it.
                Several files share one build. Each file then runs in its
                own process.
  args          Passed to main(). One pure Dart file only.

Options:
  --dart                          Build with dart compile exe.
  --flutter                       Build as a Flutter profile app.
                                  Without either, the tool uses Flutter if
                                  a file imports a Flutter package or
                                  needs dart:ui.
  -D, --dart-define=<key=value>   Define a constant. Can be repeated.
  --dart-define-from-file=<path>  Define constants from a .env or .json file.
  -h, --help                      Show this message.

The exit code is 0 only if every file exits with 0. A test file exits with
0 only if all its tests pass.

Flutter builds need the desktop platform folder (macos, linux, or windows)
in the project. As with flutter test, test files use the automated test
binding and the nearest flutter_test_config.dart. The build replaces any
profile build of the app in build/. CPU profiling works in Flutter profile
builds, but not with dart compile exe.''';

Future<void> main(List<String> arguments) async {
  final options = _Options.parse(arguments);
  if (options == null) {
    exitCode = 64;
    return;
  }

  final files = <File>[];
  for (final path in options.paths) {
    if (Directory(path).existsSync()) {
      final found =
          Directory(path)
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('_test.dart'))
              .map((f) => f.absolute)
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path));
      if (found.isEmpty) return _fail('No *_test.dart files in $path');
      files.addAll(found);
    } else if (File(path).existsSync()) {
      files.add(File(path).absolute);
    } else {
      return _fail('File not found: $path');
    }
  }

  final root = _packageRoot(files.first.parent);
  if (root == null) return _fail('No pubspec.yaml above ${files.first.path}');
  for (final file in files) {
    if (_packageRoot(file.parent)?.path != root.path) {
      return _fail('All files must be in one package: ${file.path}');
    }
  }

  final targets = [for (final file in files) _Target(root, file)];
  if (targets.length > 1 && options.args.isNotEmpty) {
    return _fail('Arguments after -- work only with one file.');
  }

  final defines = <String>[...options.defines];
  if (options.defineFile case final path?) {
    final parsed = _readDefineFile(path);
    if (parsed == null) return;
    defines.addAll(parsed);
  }

  final outDir = Directory('${root.path}/build/perf_tester_aot')
    ..createSync(recursive: true);
  final name = targets.length == 1 ? _stem(targets.single.file) : 'combined';
  final label = targets.length == 1
      ? targets.single.path
      : '${targets.length} files';

  var useFlutter = options.flutter ?? targets.any((t) => t.importsFlutter);
  if (!useFlutter) {
    // One file builds as it is, so main gets the arguments after --.
    final entry = targets.length == 1
        ? targets.single.file
        : (File('${outDir.path}/${name}_main.dart')
            ..writeAsStringSync(_dartEntry(outDir, targets)));
    final exe = await _buildDart(
      root,
      outDir,
      entry,
      name,
      label,
      defines,
      canUseFlutter: options.flutter == null,
    );
    if (targets.length > 1) _deleteEntry(entry);
    if (exe != null) {
      exitCode = await _runEach(root, targets, exe, options.args);
      return;
    }
    if (exitCode != 0) return;
    _note('The code needs dart:ui. Building it with Flutter.');
    useFlutter = true;
  }

  if (options.args.isNotEmpty) {
    return _fail('Arguments after -- work only with pure Dart files.');
  }
  final entry = File('${outDir.path}/${name}_main.dart')
    ..writeAsStringSync(_flutterEntry(outDir, targets));
  final exe = await _buildFlutter(root, entry, label, defines);
  _deleteEntry(entry);
  if (exe == null) return;
  exitCode = await _runEach(root, targets, exe, const [], flutter: true);
}

/// Runs [exe] once for each target, one at a time, and prints a summary.
/// Returns 0 if every run exits with 0.
Future<int> _runEach(
  Directory root,
  List<_Target> targets,
  String exe,
  List<String> args, {
  bool flutter = false,
}) async {
  final mode = flutter ? 'AOT, Flutter profile' : 'AOT';
  if (targets.length == 1) {
    _note('Running ($mode).');
    return _runOnce(root, exe, args, 0, flutter: flutter);
  }
  final failed = <String>[];
  for (final (i, target) in targets.indexed) {
    _note('Running ${i + 1}/${targets.length} ($mode): ${target.path}');
    final code = await _runOnce(root, exe, args, i, flutter: flutter);
    if (code != 0) failed.add('${target.path} (exit $code)');
  }
  final passed = targets.length - failed.length;
  _note('$passed of ${targets.length} files passed.');
  for (final line in failed) {
    _note('  Failed: $line');
  }
  return failed.isEmpty ? 0 : 1;
}

/// Runs [exe] for the target at [index]. Returns its exit code.
Future<int> _runOnce(
  Directory root,
  String exe,
  List<String> args,
  int index, {
  required bool flutter,
}) async {
  final environment = {_targetVariable: '$index'};
  if (!flutter) {
    final process = await Process.start(
      exe,
      args,
      workingDirectory: root.path,
      environment: environment,
      mode: ProcessStartMode.inheritStdio,
    );
    return process.exitCode;
  }
  final process = await Process.start(
    exe,
    const [],
    workingDirectory: root.path,
    environment: environment,
  );
  // The engine prefixes each print with "flutter: ".
  String strip(String line) =>
      line.startsWith('flutter: ') ? line.substring(9) : line;
  final done = [
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .forEach((line) => stdout.writeln(strip(line))),
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .forEach((line) => stderr.writeln(strip(line))),
  ];
  final code = await process.exitCode;
  await Future.wait(done);
  return code;
}

/// Deletes a generated entry point, so analysis of the project does not
/// find it.
void _deleteEntry(File entry) {
  if (entry.existsSync()) entry.deleteSync();
}

/// A file to run, and what it imports.
class _Target {
  final File file;

  /// The path relative to the package root. Names the file's group.
  final String path;

  /// 'flutter_test' or 'test' for a test file, null for a script.
  final String? harness;

  final bool importsFlutter;

  /// The flutter_test_config.dart that `flutter test` would use.
  final File? testConfig;

  factory _Target(Directory root, File file) {
    final source = file.readAsStringSync();
    bool imports(String pattern) =>
        RegExp('import\\s+[\'"]package:$pattern/').hasMatch(source);
    return _Target._(
      file,
      _relative(root, file),
      imports('flutter_test')
          ? 'flutter_test'
          : imports('test')
          ? 'test'
          : null,
      imports('flutter(_test)?'),
      _findTestConfig(root, file),
    );
  }

  _Target._(
    this.file,
    this.path,
    this.harness,
    this.importsFlutter,
    this.testConfig,
  );
}

/// Finds flutter_test_config.dart the way `flutter test` does: the nearest
/// one in the file's directory or above, up to the package root.
File? _findTestConfig(Directory root, File file) {
  for (var dir = file.parent; ; dir = dir.parent) {
    final config = File('${dir.path}/flutter_test_config.dart');
    if (config.existsSync()) return config;
    if (dir.path == root.path || dir.path == dir.parent.path) return null;
  }
}

// ── Dart ────────────────────────────────────────────────────────────────

/// Builds [entry] with `dart compile exe`. Returns the executable, or null
/// if the build failed. If [canUseFlutter] is true and the build failed only
/// because the code needs dart:ui, [exitCode] stays 0 so the caller can
/// build with Flutter. Otherwise a failed build prints its output and sets
/// [exitCode].
Future<String?> _buildDart(
  Directory root,
  Directory outDir,
  File entry,
  String name,
  String label,
  List<String> defines, {
  required bool canUseFlutter,
}) async {
  final exe = '${outDir.path}/$name${Platform.isWindows ? '.exe' : ''}';
  _note('Building $label with dart compile exe...');
  final build = await Process.run(Platform.resolvedExecutable, [
    'compile',
    'exe',
    for (final define in defines) '--define=$define',
    '-o',
    exe,
    entry.path,
  ], workingDirectory: root.path);
  if (build.exitCode == 0) return exe;
  final output = '${build.stdout}${build.stderr}';
  final needsFlutter = output.contains('dart:ui');
  if (needsFlutter && canUseFlutter) return null;
  stderr.write(output);
  _fail(
    needsFlutter
        ? 'Build failed: the code needs dart:ui. Remove --dart to build it '
              'with Flutter.'
        : 'Build failed.',
  );
  return null;
}

// ── Flutter ─────────────────────────────────────────────────────────────

/// Builds [entry] as a Flutter profile app for this computer. Returns the
/// app's executable, or null if the build failed.
Future<String?> _buildFlutter(
  Directory root,
  File entry,
  String label,
  List<String> defines,
) async {
  final platform = Platform.isMacOS
      ? 'macos'
      : Platform.isLinux
      ? 'linux'
      : Platform.isWindows
      ? 'windows'
      : null;
  if (platform == null) {
    _fail('Flutter AOT runs need macOS, Linux, or Windows.');
    return null;
  }
  if (!Directory('${root.path}/$platform').existsSync()) {
    _fail(
      'The project has no $platform folder. Add it with:\n'
      '  flutter create --platforms=$platform .',
    );
    return null;
  }

  _note('Building $label as a Flutter $platform profile app...');
  final flutter = Platform.isWindows ? 'flutter.bat' : 'flutter';
  final build = await Process.start(
    flutter,
    [
      'build',
      platform,
      '--profile',
      '-t',
      entry.path,
      for (final define in defines) '--dart-define=$define',
    ],
    workingDirectory: root.path,
    runInShell: Platform.isWindows,
  );
  final buildOutput = StringBuffer();
  build.stdout.transform(utf8.decoder).listen(buildOutput.write);
  build.stderr.transform(utf8.decoder).listen(buildOutput.write);
  final buildCode = await build.exitCode;
  if (buildCode != 0) {
    stderr.write(buildOutput);
    _fail('Build failed.');
    return null;
  }

  final exe = _findFlutterExecutable(root, platform);
  if (exe == null) {
    stderr.write(buildOutput);
    _fail('Built, but could not find the app in build/$platform.');
  }
  return exe;
}

/// The entry point for several pure Dart files. [_targetVariable] picks
/// which file's main to run.
String _dartEntry(Directory outDir, List<_Target> targets) =>
    '''
// Generated by perf_tester:aot. Do not edit.
// ignore_for_file: type=lint, avoid_dynamic_calls
import 'dart:io';

${_targetImports(outDir, targets)}

Future<void> main() async {
  final Object entry = switch (Platform.environment['$_targetVariable']) {
${[for (final (i, _) in targets.indexed) "    '$i' => t$i.main,"].join('\n')}
    final other => throw StateError('No target: \$other'),
  };
  await (entry is Function(List<String>)
      ? entry(const <String>[])
      : (entry as Function)());
}
''';

/// The Flutter entry point. [_targetVariable] picks which file's main to
/// run. It exits when that file is done, so the app does not stay open.
String _flutterEntry(Directory outDir, List<_Target> targets) {
  final configs = <String, int>{};
  for (final t in targets) {
    if (t.harness != null && t.testConfig != null) {
      configs.putIfAbsent(t.testConfig!.path, () => configs.length);
    }
  }
  final usesFlutterTest = targets.any((t) => t.harness == 'flutter_test');
  String run(int i, _Target t) {
    if (t.harness == null) return '_script(t$i.main)';
    final config = t.testConfig;
    final declare = config == null
        ? 't$i.main'
        : '() => c${configs[config.path]}.testExecutable(t$i.main)';
    return '_test($declare, automated: ${t.harness == 'flutter_test'})';
  }

  return '''
// Generated by perf_tester:aot. Do not edit.
// ignore_for_file: type=lint, avoid_dynamic_calls
import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
${usesFlutterTest ? "import 'package:flutter_test/flutter_test.dart' as harness;" : ''}
${[for (final MapEntry(:key, :value) in configs.entries) "import '${_relativeImport(outDir, File(key))}' as c$value;"].join('\n')}
${_targetImports(outDir, targets)}

Future<void> main() async {
  switch (Platform.environment['$_targetVariable']) {
${[for (final (i, t) in targets.indexed) "    case '$i':\n      await ${run(i, t)};"].join('\n')}
    case final other:
      print('No target: \$other');
      exit(1);
  }
}

/// Runs a script, then exits.
Future<void> _script(Object entry) async {
  WidgetsFlutterBinding.ensureInitialized();
  await runZonedGuarded(
    () async {
      await (entry is Function(List<String>)
          ? entry(const <String>[])
          : (entry as Function)());
      Timer(const Duration(milliseconds: 200), () => exit(0));
    },
    (error, stack) {
      print('Uncaught error: \$error\\n\$stack');
      Timer(const Duration(milliseconds: 200), () => exit(1));
    },
  );
}

/// Declares a file's tests. The test runner starts after that, and prints a
/// summary line when it is done. Exits with its result.
Future<void> _test(
  FutureOr<void> Function() declare, {
  required bool automated,
}) async {
  // flutter test uses the automated binding, with fake time. A Flutter app
  // would get the live binding, where each pump waits for a real frame.
  ${usesFlutterTest ? 'if (automated) harness.AutomatedTestWidgetsFlutterBinding.ensureInitialized();' : ''}
  await runZoned(
    () async => declare(),
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) {
        parent.print(zone, line);
        // Without the Flutter test binding, package:test prints in color.
        line = line.replaceAll(RegExp(r'\\x1B\\[[0-9;]*m'), '').trimRight();
        final passed =
            line.endsWith('All tests passed!') ||
            line.endsWith('All tests skipped.');
        if (passed || line.endsWith('Some tests failed.')) {
          // Let the output flush.
          Timer(const Duration(milliseconds: 200), () => exit(passed ? 0 : 1));
        }
      },
    ),
  );
}
''';
}

String _targetImports(Directory outDir, List<_Target> targets) => [
  for (final (i, t) in targets.indexed)
    "import '${_relativeImport(outDir, t.file)}' as t$i;",
].join('\n');

String? _findFlutterExecutable(Directory root, String platform) {
  bool isFile(FileSystemEntity e) => e is File;
  switch (platform) {
    case 'macos':
      final products = Directory(
        '${root.path}/build/macos/Build/Products/Profile',
      );
      if (!products.existsSync()) return null;
      final apps = products
          .listSync()
          .whereType<Directory>()
          .where((d) => d.path.endsWith('.app'))
          .toList();
      if (apps.length != 1) return null;
      final macOS = Directory('${apps.single.path}/Contents/MacOS');
      final exes = macOS.listSync().where(isFile).toList();
      return exes.length == 1 ? exes.single.path : null;
    case 'linux':
      final build = Directory('${root.path}/build/linux');
      if (!build.existsSync()) return null;
      for (final arch in build.listSync().whereType<Directory>()) {
        final bundle = Directory('${arch.path}/profile/bundle');
        if (!bundle.existsSync()) continue;
        final exes = bundle
            .listSync()
            .whereType<File>()
            .where((f) => f.statSync().modeString().contains('x'))
            .toList();
        if (exes.length == 1) return exes.single.path;
      }
      return null;
    case 'windows':
      final build = Directory('${root.path}/build/windows');
      if (!build.existsSync()) return null;
      for (final arch in build.listSync().whereType<Directory>()) {
        final dir = Directory('${arch.path}/runner/Profile');
        if (!dir.existsSync()) continue;
        final exes = dir
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.exe'))
            .toList();
        if (exes.length == 1) return exes.single.path;
      }
      return null;
  }
  return null;
}

// ── Helpers ─────────────────────────────────────────────────────────────

class _Options {
  final List<String> paths;
  final List<String> args;
  final List<String> defines;
  final String? defineFile;

  /// True for --flutter, false for --dart, null to choose automatically.
  final bool? flutter;

  _Options(this.paths, this.args, this.defines, this.defineFile, this.flutter);

  /// Returns null after printing usage or an error.
  static _Options? parse(List<String> arguments) {
    final paths = <String>[];
    final defines = <String>[];
    String? defineFile;
    bool? flutter;
    var args = <String>[];
    for (var i = 0; i < arguments.length; i++) {
      final arg = arguments[i];
      String? value(String name) {
        if (arg.startsWith('$name=')) return arg.substring(name.length + 1);
        if (arg == name && i + 1 < arguments.length) return arguments[++i];
        return null;
      }

      if (arg == '--') {
        args = arguments.sublist(i + 1);
        break;
      } else if (arg == '-h' || arg == '--help') {
        print(_usage);
        return null;
      } else if (arg == '--dart' || arg == '--flutter') {
        if (flutter != null) return _usageError('Use --dart or --flutter.');
        flutter = arg == '--flutter';
      } else if (arg.startsWith('--dart-define-from-file')) {
        defineFile = value('--dart-define-from-file');
        if (defineFile == null) return _usageError('Missing file: $arg');
      } else if (arg.startsWith('--dart-define') || arg.startsWith('-D')) {
        final define = arg.startsWith('-D') && arg.length > 2
            ? arg.substring(2)
            : value(arg.startsWith('-D') ? '-D' : '--dart-define');
        if (define == null || !define.contains('=')) {
          return _usageError('Expected key=value: $arg');
        }
        defines.add(define);
      } else if (arg.startsWith('-')) {
        return _usageError('Unknown option: $arg');
      } else {
        paths.add(arg);
      }
    }
    if (paths.isEmpty) return _usageError('No file given.');
    return _Options(paths, args, defines, defineFile, flutter);
  }
}

_Options? _usageError(String message) {
  stderr.writeln('$message\n\n$_usage');
  return null;
}

/// Reads key=value pairs from a .env or .json file, like
/// `flutter --dart-define-from-file`.
List<String>? _readDefineFile(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    _fail('Define file not found: $path');
    return null;
  }
  final text = file.readAsStringSync();
  if (path.endsWith('.json')) {
    final map = jsonDecode(text) as Map<String, Object?>;
    return [for (final MapEntry(:key, :value) in map.entries) '$key=$value'];
  }
  return [
    for (final raw in LineSplitter.split(text))
      if (raw.trim() case final line
          when line.isNotEmpty && !line.startsWith('#') && line.contains('='))
        () {
          final eq = line.indexOf('=');
          var value = line.substring(eq + 1).trim();
          if (value.length >= 2 &&
              (value.startsWith('"') && value.endsWith('"') ||
                  value.startsWith("'") && value.endsWith("'"))) {
            value = value.substring(1, value.length - 1);
          }
          return '${line.substring(0, eq).trim()}=$value';
        }(),
  ];
}

Directory? _packageRoot(Directory start) {
  for (Directory? dir = start; dir != null;) {
    if (File('${dir.path}/pubspec.yaml').existsSync()) return dir;
    final parent = dir.parent;
    dir = parent.path == dir.path ? null : parent;
  }
  return null;
}

String _stem(File file) {
  final name = file.uri.pathSegments.last;
  return name.endsWith('.dart') ? name.substring(0, name.length - 5) : name;
}

String _relative(Directory root, File file) =>
    file.path.startsWith('${root.path}/')
    ? file.path.substring(root.path.length + 1)
    : file.path;

/// A relative import from [from] to [to], with forward slashes.
String _relativeImport(Directory from, File to) {
  final a = from.absolute.uri.pathSegments.where((s) => s.isNotEmpty).toList();
  final b = to.absolute.uri.pathSegments;
  var common = 0;
  while (common < a.length && common < b.length - 1 && a[common] == b[common]) {
    common++;
  }
  return [
    for (var i = common; i < a.length; i++) '..',
    ...b.sublist(common),
  ].join('/');
}

void _note(String message) => stderr.writeln('[perf_tester:aot] $message');

void _fail(String message) {
  stderr.writeln('[perf_tester:aot] $message');
  exitCode = 1;
}
