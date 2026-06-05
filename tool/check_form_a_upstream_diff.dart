// tool/check_form_a_upstream_diff.dart — 形态 A 上游零侵入断言（W6.1 / Property 2）。
//
// 规则：形态 A 分支相对 base（默认 origin/main）对 **FlClash 上游既有文件** 的改动
//       只允许接缝点 #9（`lib/application.dart`）。其它上游文件（navigation/home/enum/
//       state/views/providers/models 等）零改动。`lib/xboard/**` 是我们的隔离层，不计入。
//
// 用法：dart run tool/check_form_a_upstream_diff.dart [baseRef]
// 退出码：0 = 合规；1 = 发现接缝点白名单外的上游改动；2 = git 调用失败。

import 'dart:io';

/// 接缝点白名单（允许改的 FlClash 上游既有文件）。
const _seamAllowlist = <String>{
  'lib/application.dart', // 接缝点 #9（form-a R1）
};

/// FlClash upstream 基线 commit（flclash-anchors.md 基线 = v0.8.93）。
/// 若某上游文件相对 base 有改动，但已与本基线**完全一致**，视为「回退到上游原貌」，合规
/// （form-a 升级回退了形态 B 接缝点 #6/#6.bis，使 navigation/enum/home/app_manager 复原）。
const _upstreamBaseline = 'ac2f6b9';

/// 视为「我们的隔离层 / 工程文件」的前缀（不计入上游改动）。
bool _isOurFile(String path) {
  return path.startsWith('lib/xboard/') ||
      path.startsWith('test/') ||
      path.startsWith('integration_test/') ||
      path.startsWith('tool/') ||
      path.startsWith('flavors/') ||
      path.startsWith('.kiro/') ||
      path.startsWith('.github/') ||
      path.startsWith('.githooks/') ||
      path == 'flavor_defines.json';
}

/// 该文件当前是否已与 upstream 基线一致（= 回退到原貌，非侵入）。
bool _matchesUpstream(String path) {
  final r = Process.runSync(
    'git',
    ['diff', '--quiet', _upstreamBaseline, '--', path],
  );
  // exit 0 = 无差异（与基线一致）；exit 1 = 有差异。
  return r.exitCode == 0;
}

void main(List<String> argv) {
  final base = argv.isNotEmpty ? argv.first : 'origin/main';

  final result = Process.runSync('git', ['diff', '--name-only', '$base...HEAD']);
  if (result.exitCode != 0) {
    stderr.writeln('[check-form-a-diff] git diff 失败：${result.stderr}');
    exit(2);
  }

  final changed = (result.stdout as String)
      .split('\n')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();

  final violations = <String>[];
  for (final path in changed) {
    if (_isOurFile(path)) continue; // 隔离层 / 工程文件，允许
    if (_seamAllowlist.contains(path)) continue; // 接缝点白名单
    if (_matchesUpstream(path)) continue; // 已回退到上游原貌，非侵入
    violations.add(path);
  }

  if (violations.isNotEmpty) {
    stderr.writeln('[check-form-a-diff] ✗ 形态 A 改动了接缝点白名单外的 FlClash 上游文件'
        '（${violations.length} 个）：');
    for (final v in violations) {
      stderr.writeln('  • $v');
    }
    stderr.writeln('  形态 A 只允许接缝点 #9（lib/application.dart）触碰上游；'
        '其它扩展一律放 lib/xboard/。');
    exit(1);
  }

  stdout.writeln('[check-form-a-diff] ✓ 形态 A 上游零侵入'
      '（仅接缝点 #9 application.dart；base=$base）。');
  exit(0);
}
