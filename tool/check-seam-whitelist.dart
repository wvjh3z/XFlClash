// tool/check-seam-whitelist.dart — 接缝点白名单完整性 CI 校验（conventions §1.2）。
//
// ignore_for_file: file_names
// （连字符命名与 check-line-anchors.dart / setup-hooks.sh 同款 CLI 脚本约定；非 import library。）
//
// 关联：conventions §1.2 接缝点白名单（8 处）/ .kiro/PATCHES.md / W1.7。
//
// **为什么存在（与 check-line-anchors.dart 互补）**：
//   - check-line-anchors.dart 管「已登记接缝点的行号是否漂移」
//   - 本脚本管「改了 FlClash 既有文件却没登记 PATCHES.md」—— 防白名单被静默突破
//
// 行为：
//   1. `git diff --name-only <baseline> HEAD` 列出相对 upstream 基线被改的文件
//   2. 排除我们的新增物（lib/xboard/ / test/ / tool/ / flavors/ / .githooks/ / CHANGELOG_XBOARD.md）
//      —— 新增文件「加而不改」，不占接缝点配额（conventions §1.1）
//   3. 剩下的 = 被改的 FlClash 既有文件，必须 ∈（PATCHES.md 登记的接缝点 ∪ pub-get 机械衍生白名单）
//   4. 有任何「改了但没登记」→ exit 1
//
// 用法：
//   dart run tool/check-seam-whitelist.dart                  # 默认 baseline=upstream/main
//   dart run tool/check-seam-whitelist.dart --baseline <ref>
//
// 退出码：0 = 全部已登记；1 = 有未登记改动；2 = 用法/环境错误。
//
// 纯 Dart（dart:io + Process git）；不 import Flutter/SDK，dart run 独立可跑。

import 'dart:io';

const _defaultBaseline = 'upstream/main';

/// PATCHES.md 路径（相对 XFlClash repo root）。
const _patchesRelPath = '../.kiro/PATCHES.md';

/// 我们新增物的路径前缀（「加而不改」，不占接缝点配额，diff 时排除）。
const _ourAdditions = <String>[
  'lib/xboard/',
  'test/',
  'integration_test/',
  'tool/',
  'flavors/',
  '.githooks/',
  '.github/workflows/xboard-ci.yml', // W9.8 Xboard 专属 CI（新增文件，不改 upstream workflow）
  'CHANGELOG_XBOARD.md',
  // W8.4（θ-10）新增的 backup 规则资源（新增文件，非改 upstream；AndroidManifest 引用已登记 #4.bis）。
  'android/app/src/main/res/xml/no_backup.xml',
  'android/app/src/main/res/xml/data_extraction_rules.xml',
  // W8.5.4 品牌图标/标签 flavor sourceSet（新增「加而不改」，不触碰上游 main/debug，PATCHES.md #4.ter 已登记）。
  'android/app/src/brand_a/',
  'android/app/src/brand_aDebug/',
];

/// pub get 机械衍生文件（seam #3 连带，PATCHES.md「seam #3 衍生改动」已登记，不单列接缝点）。
const _pubGetDerivatives = <String>[
  'pubspec.lock',
  'linux/flutter/generated_plugin_registrant.cc',
  'linux/flutter/generated_plugins.cmake',
  'macos/Flutter/GeneratedPluginRegistrant.swift',
  'windows/flutter/generated_plugin_registrant.cc',
  'windows/flutter/generated_plugins.cmake',
  // 构建环境衍生（Flutter 版本迁移器自动产物，PATCHES.md「构建环境衍生改动」已登记）。
  'android/gradle.properties',
  // CI 治理：禁用上游自动构建（PATCHES.md「其他 upstream 文件改动」已登记）。
  '.github/workflows/build.yaml',
  // W8.5 衍生：.gitignore 追加 flavor_config.g.dart（PATCHES.md「衍生」段已登记）。
  '.gitignore',
];

void main(List<String> argv) {
  var baseline = _defaultBaseline;
  for (var i = 0; i < argv.length; i++) {
    if (argv[i] == '--baseline' && i + 1 < argv.length) {
      baseline = argv[++i];
    } else if (argv[i] == '-h' || argv[i] == '--help') {
      stdout.writeln('用法：dart run tool/check-seam-whitelist.dart [--baseline <ref>]');
      exit(0);
    }
  }

  // 1. 解析 PATCHES.md 登记的接缝点文件
  final patchesFile = File(_patchesRelPath);
  if (!patchesFile.existsSync()) {
    stderr.writeln('[check-seam] ✗ 找不到 PATCHES.md：$_patchesRelPath');
    exit(2);
  }
  final registered = _parseRegisteredSeams(patchesFile.readAsStringSync());
  if (registered.isEmpty) {
    stderr.writeln('[check-seam] ✗ PATCHES.md 未解析到任何接缝点文件（**文件**：`XFlClash/...`）');
    exit(2);
  }

  // 2. git diff 列出相对 baseline 被改的文件（含工作树 + 已提交，覆盖 CI + pre-commit 两场景）
  final diff = Process.runSync('git', ['diff', '--name-only', baseline]);
  if (diff.exitCode != 0) {
    stderr.writeln('[check-seam] ✗ git diff 失败（baseline=$baseline 不存在？）：\n${diff.stderr}');
    exit(2);
  }
  final changed = (diff.stdout as String)
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();

  // 3. 分类
  final unregistered = <String>[];
  var registeredHits = 0;
  var derivativeHits = 0;
  var ourAdditionHits = 0;

  for (final f in changed) {
    if (_ourAdditions.any((p) => f == p || f.startsWith(p))) {
      ourAdditionHits++;
    } else if (registered.contains(f)) {
      registeredHits++;
    } else if (_pubGetDerivatives.contains(f)) {
      derivativeHits++;
    } else {
      unregistered.add(f);
    }
  }

  stdout.writeln('[check-seam] baseline=$baseline：'
      '改动 ${changed.length} 文件 → 接缝点登记 $registeredHits / '
      'pub-get 衍生 $derivativeHits / 新增物 $ourAdditionHits / '
      '✗ 未登记 ${unregistered.length}');

  if (unregistered.isNotEmpty) {
    stderr.writeln('\n--- ✗ 改了 FlClash 既有文件但未登记 PATCHES.md ---');
    for (final f in unregistered) {
      stderr.writeln('  • $f');
    }
    stderr.writeln('\n修复（conventions §1.2）：');
    stderr.writeln('  - 若是有意接缝点 → 先在 chat 确认扩白名单 → 在 PATCHES.md 加接缝点段（含 diff + 锚点）');
    stderr.writeln('  - 若是误改 upstream → git checkout 还原');
    exit(1);
  }

  stdout.writeln('[check-seam] ✓ 所有 FlClash 既有文件改动均已登记（接缝点 / pub-get 衍生）。');
  exit(0);
}

/// 解析 PATCHES.md 的 `**文件**：`XFlClash/path`` 标记 → 登记接缝点文件相对路径集。
Set<String> _parseRegisteredSeams(String md) {
  final result = <String>{};
  // 匹配 **文件**：`XFlClash/lib/main.dart`
  final re = RegExp(r'\*\*文件\*\*：`XFlClash/([^`]+)`');
  for (final m in re.allMatches(md)) {
    result.add(m.group(1)!.trim());
  }
  return result;
}
