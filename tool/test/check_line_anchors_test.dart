// W9.2.6 — check-line-anchors.dart 校验逻辑单测（提前随 DD-21 早实现一起落地）。
//
// 校验脚本是 CLI（main + exit），核心逻辑（锚点块解析 + 窗口命中 / 漂移 / 丢失三分类）
// 通过子进程跑真脚本 + 临时 fixture 文件覆盖，断言 exit code + 输出分类。
//
// 跑：flutter test tool/test/check_line_anchors_test.dart
// （纯 dart:io，无需 Flutter，但放 tool/test/ 下统一用 flutter test 跑）

import 'dart:io';

import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late String scriptPath;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('anchors_');
    // 脚本在 XFlClash/tool/ 下；测试 cwd = XFlClash repo root（flutter test 默认）。
    scriptPath = 'tool/check-line-anchors.dart';
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  /// 写一个目标源文件（被锚点指向）。
  String writeTarget(String name, List<String> lines) {
    final f = File('${tmp.path}/$name')..writeAsStringSync(lines.join('\n'));
    return f.path;
  }

  /// 写锚点 md（含 ```anchors 块）。
  String writeAnchors(List<String> anchorLines) {
    final md = StringBuffer()
      ..writeln('# test anchors')
      ..writeln('```anchors')
      ..writeln('# comment line ignored')
      ..writeAll(anchorLines.map((l) => '$l\n'))
      ..writeln('```');
    final f = File('${tmp.path}/anchors.md')..writeAsStringSync(md.toString());
    return f.path;
  }

  /// 跑脚本，返回 (exitCode, stdout+stderr)。锚点里文件路径相对 repo root，
  /// 测试用绝对路径绕过（脚本拼 `$repoRoot/$file`，故传绝对路径时 repoRoot 前缀会失效）——
  /// 改用：把 target 写到 tmp，锚点 file 列填相对 cwd 的 tmp 相对路径。
  Future<(int, String)> run(String anchorsPath) async {
    final r = await Process.run(
      'dart',
      ['run', scriptPath, '--anchors', anchorsPath],
      workingDirectory: Directory.current.path,
    );
    return (r.exitCode, '${r.stdout}\n${r.stderr}');
  }

  // 目标文件用相对 repo root 的路径（脚本以 cwd=repo root 拼接）。
  // 这里直接复用真实仓库文件 lib/main.dart 做命中/漂移断言，最贴近实战。

  test('命中：真实 main.dart runApp 在 :22 ±3 → exit 0', () async {
    final anchors = writeAnchors([
      'T-runapp | lib/main.dart | 22 | runApp(',
    ]);
    final (code, out) = await run(anchors);
    expect(code, 0, reason: out);
    expect(out, contains('全部锚点命中'));
  });

  test('漂移：故意写错行号 :99 → exit 1 + 报漂移', () async {
    final anchors = writeAnchors([
      'T-runapp | lib/main.dart | 99 | runApp(',
    ]);
    final (code, out) = await run(anchors);
    expect(code, 1, reason: out);
    expect(out, contains('行号漂移'));
    expect(out, contains('实际在'));
  });

  test('丢失：关键子串全文件找不到 → exit 1 + 报丢失', () async {
    final anchors = writeAnchors([
      'T-ghost | lib/main.dart | 22 | THIS_STRING_DOES_NOT_EXIST_ANYWHERE',
    ]);
    final (code, out) = await run(anchors);
    expect(code, 1, reason: out);
    expect(out, contains('丢失'));
  });

  test('文件不存在 → 报 missing', () async {
    final anchors = writeAnchors([
      'T-nofile | lib/does_not_exist.dart | 1 | anything',
    ]);
    final (code, out) = await run(anchors);
    expect(code, 1, reason: out);
    expect(out, contains('文件不存在'));
  });

  test('锚点块列数错（3 列）→ exit 2 解析错', () async {
    final anchors = writeAnchors([
      'T-bad | lib/main.dart | 22',
    ]);
    final (code, out) = await run(anchors);
    expect(code, 2, reason: out);
    expect(out, contains('4 列'));
  });

  test('空锚点块 → exit 2', () async {
    // 只有注释，无有效锚点行
    final f = File('${tmp.path}/empty.md')
      ..writeAsStringSync('```anchors\n# only comment\n```\n');
    final (code, out) = await run(f.path);
    expect(code, 2, reason: out);
    expect(out, contains('锚点块为空'));
  });
}
