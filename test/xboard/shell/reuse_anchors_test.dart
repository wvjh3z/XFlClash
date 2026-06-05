/// W6.2 — 形态 A 复用符号锚点守卫测试（风险②a / NFR-1.5）。
///
/// ① 跑 `tool/check-line-anchors.dart`，断言全部锚点命中（含形态 A 复用符号 + SEAM9）。
/// ② 断言锚点文件确实登记了形态 A 的复用符号（防有人删锚点导致上游 sync 漂移无人知晓）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('check-line-anchors 全命中（含形态 A 复用符号 + SEAM9）', () {
    final result = Process.runSync(
      'dart',
      ['run', 'tool/check-line-anchors.dart'],
      workingDirectory: Directory.current.path,
    );
    expect(
      result.exitCode,
      0,
      reason: '锚点漂移/丢失：\n${result.stdout}\n${result.stderr}',
    );
  });

  test('锚点文件登记了形态 A 复用符号 + 接缝点 #9', () {
    final anchorsFile = File(
      '../.kiro/specs/xboard-mvp-form-b/flclash-anchors.md',
    );
    expect(anchorsFile.existsSync(), isTrue,
        reason: '锚点文件应存在于 spec 仓');
    final content = anchorsFile.readAsStringSync();
    // 形态 A 复用的关键符号必须在锚点块登记（漂移即 CI fail）。
    for (final id in const [
      'SEAM9-home',
      'FA-startbutton',
      'FA-toolsview',
      'FA-proxygroupview',
      'FA-proxycard',
      'FA-changemode',
      'FA-isstart',
      'FA-corestatus-enum',
      'FA-traffics',
      'FA-proxiestabstate',
    ]) {
      expect(content, contains(id), reason: '缺形态 A 锚点：$id');
    }
  });
}
