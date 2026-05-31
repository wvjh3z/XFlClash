// tool/check-line-anchors.dart — DD-21 FlClash 行号锚点 CI 校验（跨平台纯 Dart）。
//
// ignore_for_file: file_names
// （文件名 check-line-anchors.dart 用连字符是 design DD-21 / tasks W9.2 / anchors.md
//  三处 spec 钉死的名字，与 setup-hooks.sh 同款 CLI 脚本命名；非 import 的 library，
//  连字符不影响功能，保留以维持 spec 一致性。）
//
// 关联：design DD-21 / flclash-anchors.md 机器可读锚点块 / PATCHES.md。
//
// **为什么存在**：design 与 PATCHES.md 钉死了数十处 FlClash 真实 file:line 引用（接缝点 /
// R7 链路 / 启动时序 / NavigationItem 等）。FlClash 是 fork，上游 sync 后这些行号会漂移。
// 本脚本机器对账「锚点行号 ±窗口 内是否含关键子串」，把「文档行号 vs 真实代码」从人工
// 肉眼核对升级为 CI gate。**这是保障上游 sync 不踩雷的核心防线。**
//
// 用法：
//   dart run tool/check-line-anchors.dart                 # 默认 ±3 行窗口
//   dart run tool/check-line-anchors.dart --window 5      # 自定义窗口
//   dart run tool/check-line-anchors.dart --anchors <path>
//
// 触发：CI 每次 build 前 / pre-commit hook / 上游 sync 后人工。
//
// 退出码：0 = 全部锚点命中；1 = 有锚点漂移/丢失；2 = 用法/解析错误。
//
// 纯 Dart（dart:io 读文件 + String.contains），**不 import package:flutter / SDK**，
// 故 `dart run` 可独立编译运行（不被 Flutter 依赖拖慢/拖崩）。

import 'dart:io';

/// 默认锚点清单路径（相对 XFlClash repo root）。
const _defaultAnchorsRelPath =
    '../.kiro/specs/xboard-mvp-form-b/flclash-anchors.md';

/// 默认行号容差窗口（±N 行）。
const _defaultWindow = 3;

class _Anchor {
  _Anchor({
    required this.id,
    required this.file,
    required this.line,
    required this.needle,
  });

  final String id;
  final String file;
  final int line;
  final String needle;
}

void main(List<String> argv) {
  var anchorsPath = _defaultAnchorsRelPath;
  var window = _defaultWindow;

  for (var i = 0; i < argv.length; i++) {
    final a = argv[i];
    if (a == '--anchors' && i + 1 < argv.length) {
      anchorsPath = argv[++i];
    } else if (a == '--window' && i + 1 < argv.length) {
      window = int.tryParse(argv[++i]) ?? _defaultWindow;
    } else if (a == '-h' || a == '--help') {
      stdout.writeln('用法：dart run tool/check-line-anchors.dart '
          '[--anchors <path>] [--window <N>]');
      exit(0);
    }
  }

  final anchorsFile = File(anchorsPath);
  if (!anchorsFile.existsSync()) {
    stderr.writeln('[check-anchors] ✗ 找不到锚点清单：$anchorsPath');
    exit(2);
  }

  final List<_Anchor> anchors;
  try {
    anchors = _parseAnchorsBlock(anchorsFile.readAsStringSync());
  } on FormatException catch (e) {
    stderr.writeln('[check-anchors] ✗ 锚点块解析失败：${e.message}');
    exit(2);
  }

  if (anchors.isEmpty) {
    stderr.writeln('[check-anchors] ✗ 锚点块为空（缺 ```anchors 代码块？）');
    exit(2);
  }

  // 锚点文件路径相对 XFlClash repo root；脚本在 repo root 下跑（cwd = XFlClash/）。
  final repoRoot = Directory.current.path;

  final drifts = <String>[];
  final missing = <String>[];
  var ok = 0;

  for (final anchor in anchors) {
    final target = File('$repoRoot/${anchor.file}');
    if (!target.existsSync()) {
      missing.add('[${anchor.id}] 文件不存在：${anchor.file}');
      continue;
    }
    final lines = target.readAsLinesSync();

    // 期望行号 ±window 窗口（1-indexed → 0-indexed，clamp 到边界）。
    final lo = (anchor.line - 1 - window).clamp(0, lines.length);
    final hi = (anchor.line - 1 + window + 1).clamp(0, lines.length);
    final window0 = lines.sublist(lo, hi);

    final hit = window0.any((l) => l.contains(anchor.needle));
    if (hit) {
      ok++;
    } else {
      // 命中失败：扫全文件看是否只是行号漂出窗口（drift）还是彻底丢失（missing）。
      final foundAt = <int>[];
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].contains(anchor.needle)) foundAt.add(i + 1);
      }
      if (foundAt.isEmpty) {
        missing.add('[${anchor.id}] ${anchor.file}:${anchor.line} '
            '关键子串彻底丢失："${anchor.needle}"（上游可能删/改了该处，需人工复扫）');
      } else {
        drifts.add('[${anchor.id}] ${anchor.file} '
            '期望 :${anchor.line}（±$window）未命中，实际在 :${foundAt.join("/")} '
            '→ 行号漂移，修订锚点块 + PATCHES.md + design');
      }
    }
  }

  stdout.writeln('[check-anchors] 锚点总数 ${anchors.length}：'
      '✓ 命中 $ok / ⚠ 漂移 ${drifts.length} / ✗ 丢失 ${missing.length}');

  if (drifts.isNotEmpty) {
    stdout.writeln('\n--- ⚠ 行号漂移（窗口外找到，需更新行号）---');
    drifts.forEach(stderr.writeln);
  }
  if (missing.isNotEmpty) {
    stdout.writeln('\n--- ✗ 关键子串丢失（上游删改，需人工复扫）---');
    missing.forEach(stderr.writeln);
  }

  if (drifts.isEmpty && missing.isEmpty) {
    stdout.writeln('[check-anchors] ✓ 全部锚点命中，FlClash 引用与真实代码一致。');
    exit(0);
  }
  exit(1);
}

/// 从 markdown 里抽取 ```anchors fenced block 并解析每行 4 列。
List<_Anchor> _parseAnchorsBlock(String md) {
  final lines = md.split('\n');
  var inBlock = false;
  final result = <_Anchor>[];

  for (final raw in lines) {
    final line = raw.trimRight();
    if (!inBlock) {
      if (line.trimLeft().startsWith('```anchors')) inBlock = true;
      continue;
    }
    if (line.trimLeft().startsWith('```')) break; // block 结束
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue; // 空行/注释

    final cols = trimmed.split('|').map((c) => c.trim()).toList();
    if (cols.length != 4) {
      throw FormatException('锚点行须 4 列（id|file|line|needle）：$trimmed');
    }
    final lineNo = int.tryParse(cols[2]);
    if (lineNo == null) {
      throw FormatException('行号非整数：$trimmed');
    }
    result.add(_Anchor(
      id: cols[0],
      file: cols[1],
      line: lineNo,
      needle: cols[3],
    ));
  }
  return result;
}
