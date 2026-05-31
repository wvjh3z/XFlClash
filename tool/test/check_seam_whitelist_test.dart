// W1.7 — check-seam-whitelist.dart 校验逻辑单测。
//
// 核心是 git diff 对账（依赖真实 repo + upstream baseline），单测覆盖：
// - 当前 repo 状态：所有 FlClash 既有改动均已登记 → exit 0
// - 注入未登记改动（临时改 upstream 既有文件）→ exit 1 + 报该文件（用后即还原）
// - baseline 不存在 → exit 2

import 'dart:io';

import 'package:test/test.dart';

void main() {
  const script = 'tool/check-seam-whitelist.dart';
  final repoRoot = Directory.current.path;

  Future<(int, String)> run({String? baseline}) async {
    final r = await Process.run(
      'dart',
      ['run', script, if (baseline != null) ...['--baseline', baseline]],
      workingDirectory: repoRoot,
    );
    return (r.exitCode, '${r.stdout}\n${r.stderr}');
  }

  test('当前 repo：所有 FlClash 既有改动均已登记 → exit 0', () async {
    final (code, out) = await run();
    expect(code, 0, reason: out);
    expect(out, contains('均已登记'));
  });

  test('注入未登记改动 → exit 1 + 报该文件（用后还原）', () async {
    // constant.dart 是 upstream 既有文件、非接缝点、非 pub-get 衍生
    final target = File('$repoRoot/lib/common/constant.dart');
    final backup = target.readAsStringSync();
    try {
      target.writeAsStringSync('$backup\n// seam-whitelist-test-marker\n');
      final (code, out) = await run();
      expect(code, 1, reason: out);
      expect(out, contains('未登记'));
      expect(out, contains('lib/common/constant.dart'));
    } finally {
      target.writeAsStringSync(backup); // 还原，绝不留痕
    }
  });

  test('baseline 不存在 → exit 2', () async {
    final (code, out) = await run(baseline: 'no-such-ref-xyz');
    expect(code, 2, reason: out);
  });
}
