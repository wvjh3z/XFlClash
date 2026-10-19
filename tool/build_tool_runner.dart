// Shared bootstrap for the Go buildkit and Rust Cargokit. No pub dependencies:
// this must run before pub get, including through Flutter plugin symlinks.
import 'dart:convert';
import 'dart:io';

Future<int> runBuildTool(List<String> args) async {
  if (args.length < 2 || !['setup', 'cargo'].contains(args[0])) {
    throw ArgumentError(
      'Expected setup/cargo and the canonical tool directory',
    );
  }
  final setup = args[0] == 'setup';
  final package = Directory('${args[1]}/build_tool');
  if (!File('${package.path}/pubspec.yaml').existsSync()) {
    throw StateError('Missing build_tool package');
  }
  final project = Directory(
    Platform.environment['PROJECT_DIR'] ?? Directory.current.path,
  ).absolute.path;
  if (setup &&
      (!File('$project/pubspec.yaml').existsSync() ||
          !Directory('$project/core').existsSync())) {
    throw StateError('Could not find project root');
  }
  final temp = setup
      ? '$project/build/setup_build_tool'
      : Platform.environment['CARGOKIT_TOOL_TEMP_DIR'];
  if (temp == null || temp.isEmpty) {
    throw StateError('CARGOKIT_TOOL_TEMP_DIR is required');
  }
  final work = Directory(temp).absolute..createSync(recursive: true);
  final lock = File(
    '${work.path}/.bootstrap.lock',
  ).openSync(mode: FileMode.append);
  try {
    await lock.lock(FileLock.blockingExclusive);
    // JSON is a YAML subset: escaping is handled by the encoder, not the shell.
    final spec = jsonEncode({
      'name': setup ? 'setup_build_tool_runner' : 'build_tool_runner',
      'version': '1.0.0',
      'publish_to': 'none',
      'environment': {'sdk': '>=3.0.0 <4.0.0'},
      'dependencies': {
        'build_tool': {'path': package.resolveSymbolicLinksSync()},
      },
    });
    File(
      '${work.path}/pubspec.yaml',
    ).writeAsStringSync('$spec\n', encoding: utf8);
    Directory('${work.path}/bin').createSync();
    File('${work.path}/bin/build_tool_runner.dart').writeAsStringSync(
      "import 'package:build_tool/build_tool.dart' as build_tool;\n"
      'void main(List<String> args) { build_tool.runMain(args); }\n',
      encoding: utf8,
    );
    // Compare source bytes, not locale-dependent DIR/ls output. Limit the
    // inventory to package inputs, excluding caches produced by local pub get.
    final inputs = <String, String>{};
    for (final name in ['pubspec.yaml', 'pubspec.lock']) {
      final file = File('${package.path}/$name');
      if (file.existsSync()) {
        inputs[name] = base64Encode(file.readAsBytesSync());
      }
    }
    for (final name in ['lib', 'bin']) {
      final directory = Directory('${package.path}/$name');
      if (!directory.existsSync()) continue;
      final files =
          directory
              .listSync(recursive: true, followLinks: false)
              .whereType<File>()
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path));
      for (final file in files) {
        inputs[file.path.substring(package.path.length)] = base64Encode(
          file.readAsBytesSync(),
        );
      }
    }
    final inventory = jsonEncode({
      'sdk': Platform.version,
      'spec': spec,
      'inputs': inputs,
      'bootstrap': base64Encode(
        File.fromUri(Platform.script).readAsBytesSync(),
      ),
    });
    final stamp = File('${work.path}/.bootstrap-inputs.json');
    final kernel = File('${work.path}/bin/build_tool_runner.dill');
    Future<int> dart(List<String> arguments) async {
      final child = await Process.start(
        Platform.resolvedExecutable,
        arguments,
        workingDirectory: work.path,
        mode: ProcessStartMode.inheritStdio,
      );
      return child.exitCode;
    }

    Future<int> compile() async {
      if (kernel.existsSync()) kernel.deleteSync();
      if (stamp.existsSync()) stamp.deleteSync();
      var code = await dart(['pub', 'get', '--no-precompile']);
      if (code != 0) return code;
      code = await dart([
        'compile',
        'kernel',
        'bin/build_tool_runner.dart',
        '-o',
        kernel.path,
      ]);
      if (code == 0) stamp.writeAsStringSync(inventory, encoding: utf8);
      return code;
    }

    if (!kernel.existsSync() ||
        !stamp.existsSync() ||
        stamp.readAsStringSync(encoding: utf8) != inventory) {
      final code = await compile();
      if (code != 0) return code;
    }
    final command = [
      kernel.path,
      ...args.skip(2),
      if (setup) ...['--root-dir', project],
    ];
    var code = await dart(command);
    if (code == 253) {
      // Retry one invalid snapshot only. Never run an old kernel after a failed
      // dependency resolution or compilation.
      code = await compile();
      if (code != 0) return code;
      code = await dart(command);
    }
    return code;
  } finally {
    await lock.close();
  }
}

Future<void> main(List<String> args) async {
  try {
    exitCode = await runBuildTool(args);
  } catch (error) {
    stderr.writeln('Build tool bootstrap failed: $error');
    exitCode = 1;
  }
}
