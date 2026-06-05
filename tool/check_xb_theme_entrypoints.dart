// tool/check_xb_theme_entrypoints.dart — 形态 A 主题作用域守卫（spec xboard-form-a-ui-revamp）。
//
// 规则（防「背景泛色/逃逸主题」回归）：
//   `lib/xboard/**` 下**禁止裸调** `showModalBottomSheet` / `showDialog` /
//   `Navigator.push(MaterialPageRoute(...))` —— 这些挂根 Navigator（FlClash MaterialApp 下），
//   逃逸 formA 品牌主题 → 徽标/按钮退回 FlClash 灰、白底被 surfaceTint 染粉红。
//
//   必须走自动套主题的统一入口：
//     - 底部 sheet → showXbBottomSheet（sheet_scaffold.dart）
//     - 对话框    → xbShowDialog（xb_theme.dart）
//     - 页面 push → xbPush（xb_theme.dart）
//
// 例外（豁免清单）：这三个 helper 自身的定义文件（它们内部必须调原生 API）。
//
// 用法：dart run tool/check_xb_theme_entrypoints.dart
// 退出码：0 = 合规；1 = 发现裸调（CI gate）。

import 'dart:io';

const _guardedRoot = 'lib/xboard/';

/// 豁免文件（helper 自身定义处，内部必须调原生 API）。
const _exemptFiles = <String>[
  'lib/xboard/shell/sheets/sheet_scaffold.dart', // showXbBottomSheet 定义
  'lib/xboard/widgets/xb_theme.dart', // xbShowDialog / xbPush 定义
  // 原生页适配器：故意 push FlClash 自己的 ToolsView，保留 FlClash 原生外观
  // （不套 formA 主题，"加而不改" 复用上游设置页）。
  'lib/xboard/shell/adapters/xb_native_page_adapter.dart',
];

/// 裸调模式 → 建议的统一入口。
final _forbidden = <RegExp, String>{
  RegExp(r'\bshowModalBottomSheet\s*[<(]'): 'showXbBottomSheet（sheet_scaffold.dart）',
  RegExp(r'\bshowDialog\s*[<(]'): 'xbShowDialog（xb_theme.dart）',
  RegExp(r'\bMaterialPageRoute\s*[<(]'): 'xbPush（xb_theme.dart）',
};

void main() {
  final root = Directory(_guardedRoot);
  if (!root.existsSync()) {
    stdout.writeln('[check-xb-theme-entrypoints] $_guardedRoot 不存在，跳过。');
    exit(0);
  }

  final exempt = _exemptFiles.map((p) => p.replaceAll(r'\', '/')).toSet();
  final violations = <String>[];

  for (final entity in root.listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    final norm = entity.path.replaceAll(r'\', '/');
    if (exempt.any(norm.endsWith)) continue;
    if (norm.contains('/generated/')) continue;

    final lines = entity.readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      // 跳过注释行（doc / 行注释里提到 API 名不算违规）。
      final trimmed = line.trimLeft();
      if (trimmed.startsWith('//') || trimmed.startsWith('///') || trimmed.startsWith('*')) {
        continue;
      }
      for (final entry in _forbidden.entries) {
        if (entry.key.hasMatch(line)) {
          violations.add('$norm:${i + 1}: 裸调 → 改用 ${entry.value}\n      $trimmed');
        }
      }
    }
  }

  if (violations.isNotEmpty) {
    stderr.writeln('[check-xb-theme-entrypoints] ✗ 主题逃逸违规（${violations.length} 处）：');
    for (final v in violations) {
      stderr.writeln('  • $v');
    }
    stderr.writeln('\n  原因：裸调挂根 Navigator，逃逸 formA 品牌主题 → 背景泛色/按钮变灰。');
    stderr.writeln('  修复：统一走 showXbBottomSheet / xbShowDialog / xbPush（自动套品牌主题）。');
    exit(1);
  }

  stdout.writeln('[check-xb-theme-entrypoints] ✓ 主题入口合规'
      '（lib/xboard/ 下无裸 showModalBottomSheet/showDialog/MaterialPageRoute）。');
  exit(0);
}
