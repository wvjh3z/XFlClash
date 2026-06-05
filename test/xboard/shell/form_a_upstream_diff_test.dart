/// W6.1 — 形态 A 上游零侵入断言测试（Property 2 / NFR-1.4）。
///
/// 跑 `tool/check_form_a_upstream_diff.dart`，断言形态 A 分支相对 origin/main 只改了
/// 接缝点 #9（lib/application.dart），其它 FlClash 上游文件零改动。
///
/// **注**：CI 用 `origin/main` 为 base；本地无 origin/main 时回退 `main`。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('形态 A 仅改接缝点 #9（application.dart），上游其余零改动', () {
    // 选 base：优先 origin/main，回退 main（本地分支无 origin 时）。
    String base = 'origin/main';
    final hasOrigin = Process.runSync('git', ['rev-parse', '--verify', 'origin/main']);
    if (hasOrigin.exitCode != 0) base = 'main';

    final result = Process.runSync(
      'dart',
      ['run', 'tool/check_form_a_upstream_diff.dart', base],
      workingDirectory: Directory.current.path,
    );
    expect(
      result.exitCode,
      0,
      reason: '形态 A 上游侵入违规：\n${result.stdout}\n${result.stderr}',
    );
  });
}
