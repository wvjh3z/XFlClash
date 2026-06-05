// tool/check_seam_imports.dart — 形态 A 适配层铁律机器校验（spec xboard-form-a-ui-revamp / W2.6）。
//
// 规则（design 适配层铁律 / NFR-1.6）：
//   `lib/xboard/shell/**`（外壳 / Tab / widget）**禁止**直接 import `package:fl_clash/views/**`
//   或 FlClash internal provider —— 一切 FlClash 内部复用必须经 `lib/xboard/shell/adapters/**` 收口。
//   仅 `adapters/**` 允许 import `lib/views/**` + FlClash 内部 provider。
//
// 用法：dart run tool/check_seam_imports.dart
// 退出码：0 = 合规；1 = 发现越界 import（CI gate）。

import 'dart:io';

/// 允许 import lib/views/** 与 FlClash 内部 provider 的目录（收口层）。
const _allowedDir = 'lib/xboard/shell/adapters/';

/// 被守卫的根目录。
const _guardedRoot = 'lib/xboard/shell/';

/// 越界 import 模式（FlClash 内部，须经 adapter 收口）。
final _forbiddenImports = <RegExp>[
  RegExp(r'''import\s+['"]package:fl_clash/views/'''),
  RegExp(r'''import\s+['"]package:fl_clash/providers/'''),
];

void main() {
  final root = Directory(_guardedRoot);
  if (!root.existsSync()) {
    stdout.writeln('[check-seam-imports] $_guardedRoot 不存在，跳过（尚未创建外壳）。');
    exit(0);
  }

  final violations = <String>[];
  for (final entity in root.listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    // adapters/ 是唯一允许收口 FlClash 内部的目录。
    if (entity.path.replaceAll(r'\', '/').contains(_allowedDir)) continue;

    final lines = entity.readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      for (final pat in _forbiddenImports) {
        if (pat.hasMatch(line)) {
          violations.add('${entity.path}:${i + 1}: $line');
        }
      }
    }
  }

  if (violations.isNotEmpty) {
    stderr.writeln(
        '[check-seam-imports] ✗ 适配层铁律违规（${violations.length} 处）—— '
        '$_guardedRoot 下非 adapters/ 文件不得直接 import lib/views/** 或 FlClash provider：');
    for (final v in violations) {
      stderr.writeln('  • $v');
    }
    stderr.writeln('  修复：把对 FlClash 内部的复用挪进 lib/xboard/shell/adapters/，Tab 只认 adapter。');
    exit(1);
  }

  stdout.writeln('[check-seam-imports] ✓ 适配层铁律合规'
      '（$_guardedRoot 下仅 adapters/ 触达 FlClash 内部）。');
  exit(0);
}
