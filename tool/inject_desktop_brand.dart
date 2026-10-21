// tool/inject_desktop_brand.dart — 桌面品牌「构建期注入」（conventions §1.2 接缝点；多品牌）。
//
// **为什么**：桌面（Windows/Linux/macOS）共用 runner 和打包元数据，构建前按
// `flavors/<flavor>/flavor.yaml` 的 appName 注入显示名。Windows 安装器公开信息独立读取
// 同品牌 windows_installer.yaml。CI（release-package.yml）在临时 checkout 注入；
// 本地构建后的生成差异按当前 DEVELOPMENT 恢复，已登记的 committed 接缝继续保留。
//
// **注入范围（仅文本/元数据，定向替换，幂等）**：
//   - Windows 窗口标题 main.cpp / Runner.rc FileDescription
//   - Linux 窗口标题 my_application.cc
//   - macOS PRODUCT_NAME（Dock/菜单名）/ Info.plist 定位权限文案 / dmg .app 名
//   - 各打包 make_config 显示名（appimage/exe/rpm/deb/dmg）统一到 appName
//   - Windows publisher_name、自有 Inno 模板可选网址、产品版本与实际构建号
//   **不动**：CFBundleURLSchemes 的 `flclash`（功能性深链）、CMake BINARY_NAME / 可执行名
//   （内部，改名风险高）、FlClashCore 等同名标识。
//
// **图标（Phase 2）**：committed 图标是上游 FlClash 的（windows app_icon.ico / macos appiconset /
//   assets/images/icon.png）。本工具构建期：
//   1) 生成 `flutter_launcher_icons.yaml`（gitignored 构建产物，image_path 指向
//      `flavors/<flavor>/assets/icons/<flavor>.png`）→ CI 随后 `dart run flutter_launcher_icons`
//      重生成 windows .ico + macOS appiconset；
//   2) 把品牌 png 覆盖到 `assets/images/icon.png` —— 同时驱动 ① Linux 打包 make_config 的
//      `icon: ./assets/images/icon.png` ② 应用内 logo（桌面标题栏 window_manager.dart / 关于页
//      about.dart）。本地跑后 `git checkout` 还原（committed 永远是 FlClash）。
//   Android 启动图标走 prepare_flavor（本工具 android:false / ios:false）。
//   3) 按目标平台复制已校验的 system_icons：Windows 三态 ICO、Linux 三态 PNG、
//      macOS 单色 template PNG。共用 PNG 路径不能混用两个平台的素材。
//
// 用法：
//   dart run tool/inject_desktop_brand.dart --flavor brand_a --platform windows --build-number 29 [--check]
//   --check：只报告将改动的文件，不写（CI 校验 / dry-run）。
//
// 退出码：0 成功；1 flavor.yaml 缺失/无 appName / 品牌图标缺失；2 用法错误。

import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'windows_installer_metadata.dart';
import 'system_icon_assets.dart';

Future<void> main(List<String> argv) async {
  final parser = ArgParser()
    ..addOption('flavor', defaultsTo: 'brand_a')
    ..addOption(
      'platform',
      allowed: ['windows', 'linux', 'macos'],
      defaultsTo: Platform.operatingSystem,
      help: '目标平台；默认当前主机，CI/本地打包显式传入',
    )
    ..addOption('build-number', help: 'Windows必填：本次Flutter编译使用的实际构建号')
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
  final platform = args['platform'] as String;
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
  final installerPath = p.join('flavors', flavor, 'windows_installer.yaml');
  final installerFile = File(installerPath);
  if (!installerFile.existsSync()) {
    stderr.writeln('[inject-desktop] ✗ 缺少公开 Windows 安装器配置：$installerPath');
    exit(1);
  }
  final Object? installerDocument;
  try {
    installerDocument = loadYaml(installerFile.readAsStringSync());
  } catch (_) {
    // YAML parser errors can include the source document; do not echo it.
    stderr.writeln('[inject-desktop] ✗ Windows 安装器配置无法读取或解析');
    exit(1);
  }
  final WindowsInstallerMetadata installer;
  try {
    installer = WindowsInstallerMetadata.fromYaml(
      installerDocument,
      defaultPublisher: name,
    );
  } on FormatException catch (error) {
    stderr.writeln('[inject-desktop] ✗ ${error.message}');
    exit(1);
  }

  final WindowsInstallerVersion? installerVersion;
  try {
    installerVersion = platform == 'windows'
        ? WindowsInstallerVersion(
            doc is YamlMap && doc['versionName'] is String
                ? doc['versionName'] as String
                : '',
            args['build-number'] as String? ?? '',
          )
        : null;
  } on FormatException catch (error) {
    stderr.writeln('[inject-desktop] ✗ ${error.message}');
    exit(1);
  }

  // Validate every resource before any text or image mutation. Builds never
  // render SVGs or launch a browser; stale/missing assets fail closed.
  final Map<String, Uint8List> systemIcons;
  try {
    final assets = await loadSystemIconAssets(
      projectRoot: Directory.current.path,
      flavor: flavor,
    );
    systemIcons = desktopSystemIconWrites(assets, platform: platform);
    applySystemIconWrites(
      projectRoot: Directory.current.path,
      writes: systemIcons,
      dryRun: true,
    );
  } catch (_) {
    stderr.writeln('[inject-desktop] ✗ 系统图标资源缺失、过期或无效；请重新生成并核对');
    exit(1);
  }

  // (相对路径, 纯变换) 表。变换幂等：已是品牌名则原样返回。
  final jobs = <String, String Function(String, String)>{
    'windows/runner/main.cpp': injectWindowsTitle,
    'windows/runner/Runner.rc': injectWindowsRc,
    'linux/runner/my_application.cc': injectLinuxTitle,
    'macos/Runner/Configs/AppInfo.xcconfig': injectMacProductName,
    'macos/Runner/Info.plist': injectMacInfoPlist,
    'macos/packaging/dmg/make_config.yaml': injectDmgMakeConfig,
    'linux/packaging/appimage/make_config.yaml': injectAppImageBrand,
    'linux/packaging/rpm/make_config.yaml': injectMakeConfigNames,
    'linux/packaging/deb/make_config.yaml': injectMakeConfigNames,
    'windows/packaging/exe/make_config.yaml': (src, app) =>
        injectWindowsInstallerConfig(
          injectMakeConfigNames(src, app),
          installer,
        ),
    'windows/packaging/exe/inno_setup.iss': (src, _) {
      final linked = injectWindowsInstallerLinks(src, installer);
      return installerVersion == null
          ? linked
          : injectWindowsInstallerVersion(linked, installerVersion);
    },
  };

  // Validate every transformation before changing files, including template markers.
  final prepared = <String, String>{};
  try {
    for (final entry in jobs.entries) {
      final file = File(entry.key);
      if (file.existsSync()) {
        prepared[entry.key] = entry.value(file.readAsStringSync(), name);
      } else if (entry.key.startsWith('windows/packaging/exe/')) {
        throw const FormatException('Windows installer input is missing');
      }
    }
  } on FormatException catch (error) {
    stderr.writeln('[inject-desktop] ✗ ${error.message}');
    exit(1);
  }

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
    final after = prepared[entry.key]!;
    if (after == before) continue;
    changed++;
    if (dryRun) {
      stdout.writeln('[inject-desktop] ~ 将改写：${entry.key}');
    } else {
      f.writeAsStringSync(after);
      stdout.writeln('[inject-desktop] ✓ 注入：${entry.key}');
    }
  }
  stdout.writeln(
    '[inject-desktop] flavor=$flavor platform=$platform appName="$name" → '
    '${dryRun ? '将改' : '已改'} $changed 文件${missing > 0 ? '（$missing 缺失跳过）' : ''}',
  );

  // ───────── Phase 2：图标 ─────────
  injectIcons(flavor, dryRun: dryRun);
  applySystemIconWrites(
    projectRoot: Directory.current.path,
    writes: systemIcons,
    dryRun: dryRun,
  );
  for (final path in systemIcons.keys) {
    stdout.writeln(
      '[inject-desktop] ${dryRun ? '~ 将覆盖' : '✓ 已校验并注入'}：$path（$platform）',
    );
  }

  exit(0);
}

/// 图标注入：① 生成 flutter_launcher_icons.yaml（CI 随后跑 flutter_launcher_icons 重生成
/// windows .ico + macOS appiconset）② 覆盖 assets/images/icon.png（Linux 打包图标 + 应用内 logo）。
void injectIcons(String flavor, {required bool dryRun}) {
  final brandPng = p.join('flavors', flavor, 'assets', 'icons', '$flavor.png');
  if (!File(brandPng).existsSync()) {
    stderr.writeln('[inject-desktop] ✗ 找不到品牌图标 $brandPng');
    exit(1);
  }

  // ① flutter_launcher_icons.yaml（gitignored 构建产物）。
  const cfgPath = 'flutter_launcher_icons.yaml';
  final cfg = buildLauncherIconsYaml(brandPng);
  if (dryRun) {
    stdout.writeln('[inject-desktop] ~ 将生成：$cfgPath（image_path=$brandPng）');
  } else {
    File(cfgPath).writeAsStringSync(cfg);
    stdout.writeln(
      '[inject-desktop] ✓ 生成：$cfgPath（CI 随后跑 flutter_launcher_icons）',
    );
  }

  // ② 覆盖应用内 / Linux 打包共用图标。
  const inAppIcon = 'assets/images/icon.png';
  if (dryRun) {
    stdout.writeln('[inject-desktop] ~ 将覆盖：$inAppIcon ← $brandPng');
  } else {
    File(brandPng).copySync(inAppIcon);
    stdout.writeln(
      '[inject-desktop] ✓ 覆盖：$inAppIcon ← $brandPng（Linux 打包 + 应用内 logo）',
    );
  }
}

/// 生成 flutter_launcher_icons 配置（仅桌面 windows/macos；Android 走 prepare_flavor，iOS 不在范围）。
/// image_path 统一用正斜杠：Windows runner 上 p.join 产出反斜杠，写进 YAML 双引号会被当转义符
/// → flutter_launcher_icons InvalidConfigException。
String buildLauncherIconsYaml(String brandPng) {
  final posix = brandPng.replaceAll(r'\', '/');
  return '''
# flutter_launcher_icons.yaml — 由 tool/inject_desktop_brand.dart 构建期生成（gitignored 产物）。
# 勿手改 / 勿提交。image_path 指向当前 flavor 的品牌图标。
flutter_launcher_icons:
  image_path: "$posix"
  android: false
  ios: false
  windows:
    generate: true
    image_path: "$posix"
    icon_size: 256
  macos:
    generate: true
    image_path: "$posix"
''';
}

// ───────── 纯变换（可单测；幂等：再跑一次结果不变）─────────

/// Windows 窗口标题使用 ASCII 源码的 Unicode 宽字符串，独立于 MSVC 代码页。
String injectWindowsTitle(String src, String appName) {
  if (appName.trim().isEmpty) {
    throw const FormatException('Windows window title must not be empty');
  }
  final escaped = StringBuffer();
  for (final rune in appName.runes) {
    if (rune < 0x20 ||
        (rune >= 0x7f && rune <= 0x9f) ||
        (rune >= 0xd800 && rune <= 0xdfff)) {
      throw const FormatException('Invalid Windows window title character');
    }
    if (rune == 0x22) {
      escaped.write(r'\"');
    } else if (rune == 0x5c) {
      escaped.write(r'\\');
    } else if (rune <= 0x7e) {
      escaped.writeCharCode(rune);
    } else {
      final width = rune <= 0xffff ? 4 : 8;
      escaped.write(rune <= 0xffff ? r'\u' : r'\U');
      escaped.write(rune.toRadixString(16).padLeft(width, '0').toUpperCase());
    }
  }
  final pattern = RegExp(
    r'(\bwindow\.Create\(\s*L")(?:[^"\\\r\n]|\\[^\r\n])*(")(?=\s*,)',
  );
  // Accept only the known runner shape: one call, one complete literal argument.
  // Matching just a prefix would leave adjacent literals or expressions behind.
  if (RegExp(r'\bwindow\.Create\s*\(').allMatches(src).length != 1 ||
      pattern.allMatches(src).length != 1) {
    throw const FormatException(
      'Expected exactly one Windows window title as a single wide string argument',
    );
  }
  return src.replaceAllMapped(pattern, (m) => '${m[1]}$escaped${m[2]}');
}

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
  RegExp(
    r'(<key>NSLocationWhenInUseUsageDescription</key>\s*<string>)FlClash(\b)',
  ),
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

/// The first AppImage keyword is the brand slot; preserve the remaining search
/// terms. Replacing that slot also handles switching brands in one checkout.
String injectAppImageBrand(String src, String appName) {
  final text = injectMakeConfigNames(src, appName).replaceAll('\r\n', '\n');
  final doc = loadYaml(text);
  if (doc is! YamlMap) {
    throw const FormatException('AppImage config must be a YAML map');
  }
  final existing = doc['keywords'];
  if (existing != null &&
      (existing is! YamlList || existing.any((value) => value is! String))) {
    throw const FormatException('AppImage keywords must be a list of strings');
  }
  final keywords = <String>{
    appName,
    if (existing is YamlList) ...existing.skip(1).cast<String>(),
  };
  final block =
      'keywords:\n${keywords.map((v) => '  - ${jsonEncode(v)}').join('\n')}';
  final pattern = RegExp(
    r'^keywords:[^\n]*(?:\n(?:[ \t]+[^\n]*|[ \t]*|#[^\n]*))*',
    multiLine: true,
  );
  if (pattern.hasMatch(text)) {
    return text.replaceFirstMapped(
      pattern,
      (match) => '$block${match[0]!.endsWith('\n') ? '\n' : ''}',
    );
  }
  return '${text.trimRight()}\n\n$block\n';
}
