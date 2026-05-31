// tool/prepare_flavor.dart — flavor.yaml 校验 + (后续 W8.5) 配置生成。
//
// 关联：design §E flavor.yaml schema + 校验项 7 项 / R14 / μ-6 μ-7 / D64。
//
// v0.1 范围（W0.5）：**schema 校验 + fail-fast**（CI 必跑）。
//   完整生成（flavor_config.g.dart / 资源拷贝 / 原生配置注入 / fallback envelope 加密）
//   由 W8.5 实施（design 决策 #4 + 跨平台矩阵 §C）。
//
// 用法：
//   dart run tool/prepare_flavor.dart --flavor brand_a [--target test]
//   校验失败 → 打印缺失/错误字段 + exit code 1（CI gate）。
//
// 退出码：0 = 校验通过；1 = 校验失败（缺字段 / 类型错 / 约束不满足）；2 = 用法错误。

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

// 🔴 W0.5 实施期 spec 订正：design §E 校验项写「调 SDK HttpConfig.hasSingleFlclashFlag」，
// 但 SDK barrel 透传 import package:flutter（http_service.dart），纯 Dart CLI（dart run）
// 无法编译 → 本校验器为可独立运行的 CI gate，**内联** flclash-flag 逻辑（与 SDK
// HttpConfig._hasSingleFlclashFlag ground truth 等价）。漂移由 prepare_flavor_test.dart
// 的 parity 测试守护（该测试 import 真 SDK，跑在 flutter test 下断言两者一致）。

/// v0.1 必填字段（design §E 最小可工作集）。
const _requiredStringKeys = <String>[
  'appName',
  'appId',
  'versionName',
  'brandColor',
  'aesKey', // 可空字符串（CI 注入），但 key 必须在
  'fallbackEnvelope',
  'subscribeUserAgent',
  'panelType',
  'currencySymbol',
  'termsUrl',
  'privacyUrl',
  'dataResidency',
  'dataController',
  'supportEmail',
];

void main(List<String> argv) {
  final parser = ArgParser()
    ..addOption('flavor', help: 'flavor 名（对应 flavors/<flavor>/）', defaultsTo: 'brand_a')
    ..addOption('target', help: 'build target（test 注入 kIsTest=true）', defaultsTo: 'prod')
    ..addFlag('help', abbr: 'h', negatable: false);

  final ArgResults args;
  try {
    args = parser.parse(argv);
  } on FormatException catch (e) {
    stderr.writeln('[prepare_flavor] 用法错误：${e.message}');
    stderr.writeln(parser.usage);
    exit(2);
  }

  if (args['help'] as bool) {
    stdout.writeln('prepare_flavor.dart — flavor.yaml 校验器（W0.5）\n');
    stdout.writeln(parser.usage);
    exit(0);
  }

  final flavor = args['flavor'] as String;
  final isTest = (args['target'] as String) == 'test';
  final flavorDir = p.join('flavors', flavor);
  final yamlPath = p.join(flavorDir, 'flavor.yaml');

  final errors = validateFlavor(yamlPath: yamlPath, flavorDir: flavorDir, isTest: isTest);

  if (errors.isNotEmpty) {
    stderr.writeln('[prepare_flavor] ✗ flavor "$flavor" 校验失败（${errors.length} 项）：');
    for (final e in errors) {
      stderr.writeln('  • $e');
    }
    exit(1);
  }

  stdout.writeln('[prepare_flavor] ✓ flavor "$flavor" 校验通过'
      '${isTest ? '（test target）' : ''}。');
  // W8.5：此处后续接 flavor_config.g.dart 生成 / 资源拷贝 / 原生配置注入。
  exit(0);
}

/// 校验 flavor.yaml，返回错误列表（空 = 通过）。
///
/// 纯函数（不退出进程），便于单测覆盖 7 校验项各 1 失败 case + 1 成功 case。
///
/// [isTest] = true 时放宽 aesKey 校验（测试 target 允许空 key，走 MemoryTokenStorage 路径）。
List<String> validateFlavor({
  required String yamlPath,
  required String flavorDir,
  bool isTest = false,
}) {
  final errors = <String>[];

  final file = File(yamlPath);
  if (!file.existsSync()) {
    return ['flavor.yaml 不存在：$yamlPath'];
  }

  final dynamic doc;
  try {
    doc = loadYaml(file.readAsStringSync());
  } on YamlException catch (e) {
    return ['flavor.yaml 解析失败：${e.message}'];
  }

  if (doc is! YamlMap) {
    return ['flavor.yaml 顶层必须是 map'];
  }

  // 1) schema 完整性 + string 类型
  for (final key in _requiredStringKeys) {
    if (!doc.containsKey(key)) {
      errors.add('缺必填字段：$key');
    } else if (doc[key] is! String) {
      errors.add('字段 $key 类型须为 string（实为 ${doc[key].runtimeType}）');
    }
  }

  // bootstrapUrls 必须是 list
  final urls = doc['bootstrapUrls'];
  if (urls == null) {
    errors.add('缺必填字段：bootstrapUrls');
  } else if (urls is! YamlList) {
    errors.add('字段 bootstrapUrls 类型须为 list');
  }

  // theme 必须是 map（含 light/dark）
  final theme = doc['theme'];
  if (theme == null) {
    errors.add('缺必填字段：theme');
  } else if (theme is! YamlMap) {
    errors.add('字段 theme 类型须为 map');
  }

  // 2) aesKey base64 解码 == 32 字节（test target 放宽空值）
  final aesKey = doc['aesKey'];
  if (aesKey is String) {
    if (aesKey.isEmpty) {
      if (!isTest) {
        errors.add('aesKey 为空：prod build 须由 CI secrets 注入 32 字节 base64 密钥');
      }
    } else {
      try {
        final bytes = base64.decode(aesKey);
        if (bytes.length != 32) {
          errors.add('aesKey base64 解码后须 == 32 字节（AES-256），实为 ${bytes.length} 字节');
        }
      } on FormatException {
        errors.add('aesKey 不是合法 base64');
      }
    }
  }

  // 3) subscribeUserAgent 含且仅含一个 flclash 子串（内联，等价 SDK ground truth）
  final ua = doc['subscribeUserAgent'];
  if (ua is String && !hasSingleFlclashFlag(ua)) {
    errors.add('subscribeUserAgent 必须含且仅含一个 "flclash" 子串（F202/F203）：实为 "$ua"');
  }

  // 4) bootstrapUrls length ≥ 3 + 全 https valid URL
  if (urls is YamlList) {
    if (urls.length < 3) {
      errors.add('bootstrapUrls 须 ≥ 3 个镜像（实为 ${urls.length}）');
    }
    for (final u in urls) {
      if (u is! String || !_isHttpsUrl(u)) {
        errors.add('bootstrapUrls 含非法 https URL：$u');
      }
    }
  }

  // 5) 资源目录：icon（命名跟随 flavor 目录名，design：assets/icons/<flavor>.png）+ fallbackEnvelope 存在
  final flavorName = p.basename(flavorDir);
  final realIcon = p.join(flavorDir, 'assets', 'icons', '$flavorName.png');
  if (!File(realIcon).existsSync()) {
    errors.add('缺 flavor icon：$realIcon');
  }
  final fallback = doc['fallbackEnvelope'];
  if (fallback is String && fallback.isNotEmpty) {
    final fallbackPath = p.join(flavorDir, fallback);
    if (!File(fallbackPath).existsSync()) {
      errors.add('缺 fallbackEnvelope 文件：$fallbackPath');
    }
  }

  // 6) termsUrl / privacyUrl 非空 + 合法 URL
  for (final key in ['termsUrl', 'privacyUrl']) {
    final v = doc[key];
    if (v is String && (v.isEmpty || !_isHttpUrl(v))) {
      errors.add('$key 须为非空合法 URL：实为 "$v"');
    }
  }

  // 6.5) versionName 须合法 SemVer（产品版本，conventions §2.8 双轨版本号）
  //      W8.5 注入 pubspec version = `${versionName}+flclash${upstreamTag}`，
  //      versionName 非法会污染最终 app 版本号 + 破坏 v0.3 自更新版本比较。
  final versionName = doc['versionName'];
  if (versionName is String && !_isSemVer(versionName)) {
    errors.add('versionName 须为合法 SemVer（如 0.1.0），实为 "$versionName"'
        '（conventions §2.8 — 注入 pubspec version=<versionName>+flclash<底座>）');
  }

  // 7) theme.dark 与 light 同键集
  if (theme is YamlMap) {
    final light = theme['light'];
    final dark = theme['dark'];
    if (light is! YamlMap) {
      errors.add('theme.light 须为 map');
    }
    if (dark is! YamlMap) {
      errors.add('theme.dark 须为 map');
    }
    if (light is YamlMap && dark is YamlMap) {
      final lightKeys = light.keys.toSet();
      final darkKeys = dark.keys.toSet();
      if (!_setEquals(lightKeys, darkKeys)) {
        errors.add('theme.dark 键集须与 light 一致：light=$lightKeys dark=$darkKeys');
      }
    }
  }

  return errors;
}

/// 校验 UA 含且仅含一个 'flclash' 子串（大小写不敏感）。
///
/// 内联自 SDK `HttpConfig._hasSingleFlclashFlag`（ground truth）；逻辑等价由
/// `tool/test/prepare_flavor_test.dart` 的 parity 测试守护（import 真 SDK 断言一致）。
bool hasSingleFlclashFlag(String ua) {
  final lower = ua.toLowerCase();
  var count = 0;
  var idx = 0;
  while (true) {
    final found = lower.indexOf('flclash', idx);
    if (found == -1) break;
    count++;
    if (count > 1) return false;
    idx = found + 'flclash'.length;
  }
  return count == 1;
}

bool _isHttpsUrl(String s) {
  final uri = Uri.tryParse(s);
  return uri != null && uri.scheme == 'https' && uri.host.isNotEmpty;
}

bool _isHttpUrl(String s) {
  final uri = Uri.tryParse(s);
  return uri != null &&
      (uri.scheme == 'https' || uri.scheme == 'http') &&
      uri.host.isNotEmpty;
}

/// 简化 SemVer 校验：MAJOR.MINOR.PATCH（可带 -prerelease / +build）。
/// 产品版本号（conventions §2.8）；不接受上游 FlClash 的 `0.8.93+2026052901` 风格也 OK，
/// 因为我们的 versionName 是独立产品版本（如 0.1.0）。
bool _isSemVer(String s) =>
    RegExp(r'^\d+\.\d+\.\d+([-+][0-9A-Za-z.-]+)?$').hasMatch(s);

bool _setEquals(Set<Object?> a, Set<Object?> b) =>
    a.length == b.length && a.every(b.contains);
