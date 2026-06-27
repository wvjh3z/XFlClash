// tool/inject_desktop_brand.dart — 桌面品牌「构建期注入」（conventions §1.2 接缝点；多品牌）。
//
// **为什么**：桌面（Windows/Linux/macOS）无 Flutter flavor 机制，runner/打包元数据是
// 共用的上游 FlClash 文件。committed 文件保持上游原样（FlClash，零侵入、可 sync）；**构建前**
// 由本工具按 `flavors/<flavor>/flavor.yaml` 的 appName 改写为品牌名 → 桌面构建产物显示品牌、
// 不再显 FlClash。CI（release-build.yml）fresh checkout 上跑，无脏树问题；本地跑后可
// `git checkout` 还原（committed 永远是 FlClash）。
//
// **注入范围（仅文本/元数据，定向替换，幂等）**：
//   - Windows 窗口标题 main.cpp / Runner.rc FileDescription
//   - Linux 窗口标题 my_application.cc
//   - macOS PRODUCT_NAME（Dock/菜单名）/ Info.plist 定位权限文案 / dmg .app 名
//   - 各打包 make_config 显示名（appimage/exe/rpm/deb/dmg）统一到 appName
//   **不动**：CFBundleURLSchemes 的 `flclash`（功能性深链）、CMake BINARY_NAME / 可执行名
//   （内部，改名风险高）、FlClashCore 等同名标识。图标（.ico/.icns/png）走 CI（本工具不碰）。
//
// 用法：
//   dart run tool/inject_desktop_brand.dart --flavor brand_a [--check]
//   --check：只报告将改动的文件，不写（CI 校验 / dry-run）。
//
// 退出码：0 成功；1 flavor.yaml 缺失/无 appName；2 用法错误。

import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

void main(List<String> argv) {
  final parser = ArgParser()
    ..addOption('flavor', defaultsTo: 'brand_a')
    ..addFlag('check', negatable: false, help: 'dry-run：只报告不写')
    ..addFlag('help', abbr: 'h', negatable: false);
  final ArgResults args;
  try {
    args = parser.parse(argv);
  } on FormatException catch (e) {
    stderr.writeln('[inject-desktop] 用法错误：${e.message}\n${parser.usage}');
    exit(2);
  }
  if (args['help'] as bool) {
    stdout.writeln('inject_desktop_brand.dart — 桌面品牌构建期注入\n${parser.usage}');
    exit(0);
  }

  final flavor = args['flavor'] as String;
  final dryRun = args['check'] as bool;
  final yamlPath = p.join('flavors', flavor, 'flavor.yaml');
  final yf = File(yamlPath);
  if (!yf.existsSync()) {
    stderr.writeln('[inject-desktop] ✗ 找不到 $yamlPath');
    exit(1);
  }
  final doc = loadYaml(yf.readAsStringSync());
  final appName = (doc is YamlMap ? doc['appName'] : null) as String?;
  if (appName == null || appName.trim().isEmpty) {
    stderr.writeln('[inject-desktop] ✗ flavor.yaml 缺 appName');
    exit(1);
  }
  final name = appName.trim();

  // (相对路径, 纯变换) 表。变换幂等：已是品牌名则原样返回。
  final jobs = <String, String Function(String, String)>{
    'windows/runner/main.cpp': injectWindowsTitle,
    'windows/runner/Runner.rc': injectWindowsRc,
    'linux/runner/my_application.cc': injectLinuxTitle,
    'macos/Runner/Configs/AppInfo.xcconfig': injectMacProductName,
    'macos/Runner/Info.plist': injectMacInfoPlist,
    'macos/packaging/dmg/make_config.yaml': injectDmgMakeConfig,
    'linux/packaging/appimage/make_config.yaml': injectMakeConfigNames,
    'linux/packaging/rpm/make_config.yaml': injectMakeConfigNames,
    'linux/packaging/deb/make_config.yaml': injectMakeConfigNames,
    'windows/packaging/exe/make_config.yaml': injectMakeConfigNames,
  };

  var changed = 0;
  var missing = 0;
  for (final entry in jobs.entries) {
    final f = File(entry.key);
    if (!f.existsSync()) {
      missing++;
      stdout.writeln('[inject-desktop] - 跳过（不存在）：${entry.key}');
      continue;
    }
    final before = f.readAsStringSync();
    final after = entry.value(before, name);
    if (after == before) continue;
    changed++;
    if (dryRun) {
      stdout.writeln('[inject-desktop] ~ 将改写：${entry.key}');
    } else {
      f.writeAsStringSync(after);
      stdout.writeln('[inject-desktop] ✓ 注入：${entry.key}');
    }
  }
  stdout.writeln('[inject-desktop] flavor=$flavor appName="$name" → '
      '${dryRun ? '将改' : '已改'} $changed 文件${missing > 0 ? '（$missing 缺失跳过）' : ''}');
  exit(0);
}

// ───────── 纯变换（可单测；幂等：再跑一次结果不变）─────────

/// Windows 窗口标题：`window.Create(L"<旧>"` → `L"<appName>"`。
String injectWindowsTitle(String src, String appName) => src.replaceAllMapped(
      RegExp(r'(\.Create\(\s*L")[^"]*(")'),
      (m) => '${m[1]}$appName${m[2]}',
    );

/// Windows Runner.rc：FileDescription 值 → appName（不动 InternalName/ProductName=clash）。
String injectWindowsRc(String src, String appName) => src.replaceAllMapped(
      RegExp(r'(VALUE\s+"FileDescription",\s*")[^"]*(")'),
      (m) => '${m[1]}$appName${m[2]}',
    );

/// Linux 窗口标题：`gtk_header_bar_set_title(...,"<旧>")` + `gtk_window_set_title(...,"<旧>")`。
String injectLinuxTitle(String src, String appName) => src.replaceAllMapped(
      RegExp(r'(gtk_(?:header_bar|window)_set_title\([^,]+,\s*")[^"]*(")'),
      (m) => '${m[1]}$appName${m[2]}',
    );

/// macOS PRODUCT_NAME（驱动 .app 名 + Dock/菜单显示）。
String injectMacProductName(String src, String appName) => src.replaceAllMapped(
      RegExp(r'^(PRODUCT_NAME\s*=\s*).*$', multiLine: true),
      (m) => '${m[1]}$appName',
    );

/// macOS Info.plist：定位权限文案里的「FlClash」品牌词 → appName（仅那条 usage 文案）。
/// 只替换 NSLocation...UsageDescription 文案开头的品牌名，**不动** CFBundleURLSchemes。
String injectMacInfoPlist(String src, String appName) => src.replaceAllMapped(
      RegExp(r'(<key>NSLocationWhenInUseUsageDescription</key>\s*<string>)FlClash(\b)'),
      (m) => '${m[1]}$appName${m[2]}',
    );

/// macOS dmg make_config：`title:` + 文件项 `path: <旧>.app` → appName（须与 PRODUCT_NAME 一致）。
String injectDmgMakeConfig(String src, String appName) {
  var s = src.replaceAllMapped(
    RegExp(r'^(title:\s*).*$', multiLine: true),
    (m) => '${m[1]}$appName',
  );
  s = s.replaceAllMapped(
    RegExp(r'(path:\s*")[^"]*\.app(")'),
    (m) => '${m[1]}$appName.app${m[2]}',
  );
  // 无引号形式 path: Xxx.app
  s = s.replaceAllMapped(
    RegExp(r'^(\s*path:\s*)(?!")[^\s"]+\.app\s*$', multiLine: true),
    (m) => '${m[1]}$appName.app',
  );
  return s;
}

/// 通用打包 make_config：display_name / app_name / generic_name / title → appName（统一品牌名）。
/// 不动 app_id / publisher / package_name / executable_name / output_base_file_name 等（非显示名）。
String injectMakeConfigNames(String src, String appName) {
  var s = src;
  for (final key in ['display_name', 'app_name', 'generic_name', 'title']) {
    s = s.replaceAllMapped(
      RegExp('^($key:\\s*).*\$', multiLine: true),
      (m) => '${m[1]}$appName',
    );
  }
  return s;
}
