import 'dart:io';

Future<void> main(List<String> args) async {
  final here = File(Platform.script.toFilePath()).resolveSymbolicLinksSync();
  final directory = File(here).parent;
  final root = directory.parent.parent.parent;
  final child = await Process.start(Platform.resolvedExecutable, [
    '${root.path}/tool/build_tool_runner.dart',
    'setup',
    directory.path,
    ...args,
  ], mode: ProcessStartMode.inheritStdio);
  exitCode = await child.exitCode;
}
