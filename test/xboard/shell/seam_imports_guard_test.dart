/// W2.6 — 适配层铁律守卫测试（NFR-1.6 / design 适配层铁律）。
///
/// 跑 `tool/check_seam_imports.dart`，断言当前 `lib/xboard/shell/` 合规（exit 0）。
/// 该脚本同时进 CI（formA build 前），防 Tab 直接 import lib/views/** 绕过 adapter 收口。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('lib/xboard/shell/ 适配层铁律合规（仅 adapters/ 触达 FlClash 内部）', () {
    final result = Process.runSync(
      'dart',
      ['run', 'tool/check_seam_imports.dart'],
      workingDirectory: Directory.current.path,
    );
    expect(
      result.exitCode,
      0,
      reason: '适配层铁律违规：\n${result.stdout}\n${result.stderr}',
    );
  });
}
