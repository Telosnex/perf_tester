// Runs a benchmark file compiled ahead of time (AOT), so timing comparisons
// are not affected by the JIT.
//
//   dart run perf_tester:aot [options] <file.dart> [-- args...]
//
// Pure Dart files are built with `dart compile exe`. Files that need
// Flutter are built as a Flutter profile app for this computer and run
// directly. A file can be a script with `main`, or a test file that uses
// package:test or package:flutter_test, `testWidgets` included.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

const _usage = '''
Runs a Dart or Flutter benchmark file compiled ahead of time (AOT).

Usage: dart run perf_tester:aot [options] <file.dart> [-- args...]

  <file.dart>   A script with main(), or a test file (package:test or
                package:flutter_test, testWidgets included).
  args          Passed to main(). Pure Dart files only.

Options:
  --dart                          Build with dart compile exe.
  --flutter                       Build as a Flutter profile app.
                                  Without either, the tool uses Flutter if
                                  the file imports a Flutter package or
                                  needs dart:ui.
  -D, --dart-define=<key=value>   Define a constant. Can be repeated.
  --dart-define-from-file=<path>  Define constants from a .env or .json file.
  -h, --help                      Show this message.

The exit code is the program's exit code. A test file exits with 0 only if
all tests pass.

Flutter files need the desktop platform folder (macos, linux, or windows)
in the project. The build replaces any profile build of the app in build/.
CPU profiling works in Flutter profile builds, but not with dart compile exe.''';

Future<void> main(List<String> arguments) async {
  final options = _Options.parse(arguments);
  if (options == null) {
    exitCode = 64;
    return;
  }

  final file = File(options.file).absolute;
  if (!file.existsSync()) {
    _fail('File not found: ${options.file}');
    return;
  }
  final root = _packageRoot(file.parent);
  if (root == null) {
    _fail('No pubspec.yaml above ${file.path}');
    return;
  }

  final defines = <String>[...options.defines];
  if (options.defineFile case final path?) {
    final parsed = _readDefineFile(path);
    if (parsed == null) return;
    defines.addAll(parsed);
  }

  final source = file.readAsStringSync();
  var useFlutter =
      options.flutter ??
      RegExp(r'''import\s+['"]package:flutter(_test)?/''').hasMatch(source);

  if (!useFlutter) {
    final code = await _runDart(root, file, defines, options.args);
    if (code == null && options.flutter == null) {
      _note('The file needs dart:ui. Building it with Flutter.');
      useFlutter = true;
    } else {
      exitCode = code ?? 1;
      return;
    }
  }

  if (options.args.isNotEmpty) {
    _fail('Arguments after -- work only with pure Dart files.');
    return;
  }
  exitCode = await _runFlutter(root, file, source, defines);
}

// ── Dart ────────────────────────────────────────────────────────────────

/// Builds [file] with `dart compile exe` and runs it. Returns the exit
/// code, or null if the build failed because the file needs dart:ui.
Future<int?> _runDart(
  Directory root,
  File file,
  List<String> defines,
  List<String> args,
) async {
  final outDir = Directory('${root.path}/build/perf_tester_aot')
    ..createSync(recursive: true);
  final exe =
      '${outDir.path}/${_stem(file)}${Platform.isWindows ? '.exe' : ''}';

  _note('Building ${_relative(root, file)} with dart compile exe...');
  final build = await Process.run(Platform.resolvedExecutable, [
    'compile',
    'exe',
    for (final define in defines) '--define=$define',
    '-o',
    exe,
    file.path,
  ], workingDirectory: root.path);
  if (build.exitCode != 0) {
    final output = '${build.stdout}${build.stderr}';
    if (output.contains('dart:ui')) return null;
    stderr.write(output);
    _note('Build failed.');
    return build.exitCode;
  }

  _note('Running (AOT).');
  final process = await Process.start(
    exe,
    args,
    workingDirectory: root.path,
    mode: ProcessStartMode.inheritStdio,
  );
  return process.exitCode;
}

// ── Flutter ─────────────────────────────────────────────────────────────

/// Builds [file] as a Flutter profile app for this computer and runs it.
Future<int> _runFlutter(
  Directory root,
  File file,
  String source,
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
    return 1;
  }
  if (!Directory('${root.path}/$platform').existsSync()) {
    _fail(
      'The project has no $platform folder. Add it with:\n'
      '  flutter create --platforms=$platform .',
    );
    return 1;
  }

  final outDir = Directory('${root.path}/build/perf_tester_aot')
    ..createSync(recursive: true);
  final entry = File('${outDir.path}/${_stem(file)}_main.dart')
    ..writeAsStringSync(_flutterEntry(outDir, file, source));

  _note(
    'Building ${_relative(root, file)} as a Flutter $platform profile app...',
  );
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
    _note('Build failed.');
    return buildCode;
  }

  final exe = _findFlutterExecutable(root, platform);
  if (exe == null) {
    stderr.write(buildOutput);
    _fail('Built, but could not find the app in build/$platform.');
    return 1;
  }

  _note('Running (AOT, Flutter profile).');
  final process = await Process.start(
    exe,
    const [],
    workingDirectory: root.path,
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

/// The generated entry point. It runs [file]'s main and exits when it is
/// done, so the app does not stay open.
String _flutterEntry(Directory outDir, File file, String source) {
  final import = _relativeImport(outDir, file);
  final isTest = RegExp(
    r'''import\s+['"]package:(flutter_test|test|test_api)/''',
  ).hasMatch(source);
  final run = isTest
      ? '''
  // Test files: flutter_test runs the tests after main returns, then prints
  // a summary line.
  runZoned(
    () => target.main(),
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) {
        parent.print(zone, line);
        final passed =
            line.endsWith('All tests passed!') ||
            line.endsWith('All tests skipped.');
        if (passed || line.endsWith('Some tests failed.')) {
          // Let the output flush.
          Timer(const Duration(milliseconds: 200), () => exit(passed ? 0 : 1));
        }
      },
    ),
  );'''
      : '''
  // Scripts: exit when main completes.
  WidgetsFlutterBinding.ensureInitialized();
  runZonedGuarded(
    () async {
      final Object entry = target.main;
      await (entry is Function(List<String>)
          ? entry(const <String>[])
          : (entry as Function)());
      Timer(const Duration(milliseconds: 200), () => exit(0));
    },
    (error, stack) {
      print('Uncaught error: \$error\\n\$stack');
      Timer(const Duration(milliseconds: 200), () => exit(1));
    },
  );''';
  return '''
// Generated by perf_tester:aot. Do not edit.
// ignore_for_file: type=lint, avoid_dynamic_calls
import 'dart:async';
import 'dart:io';
${isTest ? '' : "\nimport 'package:flutter/widgets.dart';\n"}
import '$import' as target;

void main() {
$run
}
''';
}

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
  final String file;
  final List<String> args;
  final List<String> defines;
  final String? defineFile;

  /// True for --flutter, false for --dart, null to choose automatically.
  final bool? flutter;

  _Options(this.file, this.args, this.defines, this.defineFile, this.flutter);

  /// Returns null after printing usage or an error.
  static _Options? parse(List<String> arguments) {
    String? file;
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
      } else if (file == null) {
        file = arg;
      } else {
        return _usageError('Put arguments for main() after --.');
      }
    }
    if (file == null) return _usageError('No file given.');
    return _Options(file, args, defines, defineFile, flutter);
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
