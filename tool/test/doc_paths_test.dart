// Documentation migration: run the real CLIs against isolated workspaces.
import 'dart:io';

import 'package:test/test.dart';

void main() {
  final toolsDir = '${Directory.current.path}/tool';
  late Directory workspace;
  late Directory repo;

  setUp(() {
    workspace = Directory.systemTemp.createTempSync('xboard_doc_paths_');
    repo = Directory('${workspace.path}/XFlclash')..createSync();
    final source = File('${repo.path}/lib/main.dart');
    source.parent.createSync(recursive: true);
    source.writeAsStringSync('// anchor-target\n');
    for (final args in <List<String>>[
      ['init'],
      ['add', '.'],
      ['commit', '-m', 'fixture baseline'],
    ]) {
      final result = Process.runSync('git', [
        '-c', 'core.hooksPath=/dev/null',
        '-c', 'user.name=anonymous',
        '-c', 'user.email=anonymous@users.noreply.github.com',
        ...args,
      ], workingDirectory: repo.path);
      expect(result.exitCode, 0, reason: '${result.stderr}');
    }
    source.writeAsStringSync('// anchor-target\n// changed\n');
  });

  tearDown(() => workspace.deleteSync(recursive: true));

  for (final anchors in [true, false]) {
    final script = anchors
        ? 'check-line-anchors.dart'
        : 'check-seam-whitelist.dart';
    final tail = anchors
        ? 'specs/xboard-mvp-form-b/flclash-anchors.md'
        : 'PATCHES.md';
    final currentName = anchors ? 'FLCLASH_ANCHORS.md' : 'PATCHES.md';

    File writeDoc(String path, {bool valid = true}) {
      final file = File(path);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(anchors
          ? '```anchors\nT|lib/main.dart|1|${valid ? 'anchor-target' : 'missing-needle'}\n```\n'
          : '**文件**：`XFlClash/${valid ? 'lib/main.dart' : 'lib/state.dart'}`\n');
      return file;
    }

    Future<ProcessResult> run({File? explicit}) => Process.run('dart', [
      'run', '$toolsDir/$script',
      if (!anchors) ...['--baseline', 'HEAD'],
      if (explicit != null) ...[anchors ? '--anchors' : '--patches', explicit.path],
    ], workingDirectory: repo.path);

    test('$script prefers current Docs files over both older layouts', () async {
      writeDoc('${workspace.path}/Docs/$currentName');
      writeDoc('${workspace.path}/Docs/Multi-platform-client-spec/.kiro/$tail',
          valid: false);
      writeDoc('${workspace.path}/.kiro/$tail', valid: false);
      final result = await run();
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    });

    test('$script falls back to the intermediate Docs layout', () async {
      writeDoc('${workspace.path}/Docs/Multi-platform-client-spec/.kiro/$tail');
      writeDoc('${workspace.path}/.kiro/$tail', valid: false);
      final result = await run();
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    });

    test('$script falls back to the old layout', () async {
      writeDoc('${workspace.path}/.kiro/$tail');
      final result = await run();
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    });

    test('$script explicit path overrides the default', () async {
      writeDoc('${workspace.path}/Docs/$currentName', valid: false);
      final explicit = writeDoc('${workspace.path}/custom/$tail');
      final result = await run(explicit: explicit);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    });

    test('$script fails when no document is available', () async {
      final result = await run();
      expect(result.exitCode, 2, reason: '${result.stdout}\n${result.stderr}');
    });
  }
}
