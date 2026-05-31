// W0.5.8 — prepare_flavor.dart 校验器单测：7 校验项各 1 失败 case + 1 成功 case。
//
// 用 dart:io 临时目录构造 flavor.yaml + 资源文件，调纯函数 validateFlavor 断言错误列表。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart' show HttpConfig;
import 'package:test/test.dart';

// 直接引相对路径脚本（tool/ 不是 package lib，用相对 import）。
import '../prepare_flavor.dart';

/// 一份完整合法的 flavor.yaml 内容模板（各 case 在此基础上改坏一处）。
String _validYaml({
  String aesKey = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=', // 32 字节 base64
  String ua = 'MyClient/0.1.0 flclash',
  List<String> urls = const [
    'https://a.example.com/b.bin',
    'https://b.example.com/b.bin',
    'https://c.example.com/b.bin',
  ],
  String termsUrl = 'https://example.com/terms',
  String darkTheme = '{ primary: "#ff5a4a", surface: "#1a1a1a", error: "#cf6679" }',
  bool dropAppName = false,
}) {
  final urlsBlock = urls.map((u) => '  - "$u"').join('\n');
  return '''
${dropAppName ? '' : 'appName: "MyClient"'}
appId: "com.example.myclient"
versionName: "0.1.0"
brandColor: "#d92e1a"
aesKey: "$aesKey"
bootstrapUrls:
$urlsBlock
fallbackEnvelope: "assets/fallback.bin"
subscribeUserAgent: "$ua"
sentryDsn: ""
panelType: "xboard"
currencySymbol: "¥"
termsUrl: "$termsUrl"
privacyUrl: "https://example.com/privacy"
dataResidency: "Hong Kong"
dataController: "Example Tech Co., Ltd."
supportEmail: "support@example.com"
theme:
  light: { primary: "#d92e1a", surface: "#ffffff", error: "#b00020" }
  dark:  $darkTheme
''';
}

void main() {
  late Directory tmp;
  late String flavorDir;
  late String yamlPath;

  /// 在临时 flavor 目录写入 yaml + 资源文件。
  void writeFlavor(String yaml, {bool withIcon = true, bool withFallback = true}) {
    Directory(pJoin(flavorDir, 'assets', 'icons')).createSync(recursive: true);
    if (withIcon) {
      File(pJoin(flavorDir, 'assets', 'icons', 'brand_a.png'))
          .writeAsBytesSync([0x89, 0x50, 0x4e, 0x47]);
    }
    if (withFallback) {
      File(pJoin(flavorDir, 'assets', 'fallback.bin')).writeAsStringSync('x');
    }
    File(yamlPath).writeAsStringSync(yaml);
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('prepflavor_');
    flavorDir = pJoin(tmp.path, 'brand_a');
    Directory(flavorDir).createSync(recursive: true);
    yamlPath = pJoin(flavorDir, 'flavor.yaml');
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  test('✅ 成功 case：完整合法 flavor.yaml → 0 错误', () {
    writeFlavor(_validYaml());
    final errors = validateFlavor(yamlPath: yamlPath, flavorDir: flavorDir);
    expect(errors, isEmpty, reason: errors.join('\n'));
  });

  test('① schema 完整性：缺 appName → 报缺字段', () {
    writeFlavor(_validYaml(dropAppName: true));
    final errors = validateFlavor(yamlPath: yamlPath, flavorDir: flavorDir);
    expect(errors, contains(matches(r'缺必填字段：appName')));
  });

  test('② aesKey 非 32 字节 → 报错', () {
    writeFlavor(_validYaml(aesKey: base64.encode(List.filled(16, 0)))); // 16 字节
    final errors = validateFlavor(yamlPath: yamlPath, flavorDir: flavorDir);
    expect(errors.any((e) => e.contains('aesKey') && e.contains('32 字节')), isTrue);
  });

  test('② aesKey 空 + test target → 放宽通过', () {
    writeFlavor(_validYaml(aesKey: ''));
    final errors =
        validateFlavor(yamlPath: yamlPath, flavorDir: flavorDir, isTest: true);
    expect(errors, isEmpty, reason: errors.join('\n'));
  });

  test('③ subscribeUserAgent 双 flclash → 报错', () {
    writeFlavor(_validYaml(ua: 'FlClash-MyClient flclash'));
    final errors = validateFlavor(yamlPath: yamlPath, flavorDir: flavorDir);
    expect(errors.any((e) => e.contains('flclash')), isTrue);
  });

  test('④ bootstrapUrls < 3 → 报错', () {
    writeFlavor(_validYaml(urls: ['https://a.example.com/b.bin']));
    final errors = validateFlavor(yamlPath: yamlPath, flavorDir: flavorDir);
    expect(errors.any((e) => e.contains('bootstrapUrls') && e.contains('≥ 3')), isTrue);
  });

  test('④ bootstrapUrls 含非 https → 报错', () {
    writeFlavor(_validYaml(urls: [
      'http://a.example.com/b.bin',
      'https://b.example.com/b.bin',
      'https://c.example.com/b.bin',
    ]));
    final errors = validateFlavor(yamlPath: yamlPath, flavorDir: flavorDir);
    expect(errors.any((e) => e.contains('非法 https URL')), isTrue);
  });

  test('⑤ 缺 fallback.bin → 报错', () {
    writeFlavor(_validYaml(), withFallback: false);
    final errors = validateFlavor(yamlPath: yamlPath, flavorDir: flavorDir);
    expect(errors.any((e) => e.contains('fallbackEnvelope')), isTrue);
  });

  test('⑤ 缺 icon → 报错', () {
    writeFlavor(_validYaml(), withIcon: false);
    final errors = validateFlavor(yamlPath: yamlPath, flavorDir: flavorDir);
    expect(errors.any((e) => e.contains('flavor icon')), isTrue);
  });

  test('⑥ termsUrl 非法 URL → 报错', () {
    writeFlavor(_validYaml(termsUrl: 'not-a-url'));
    final errors = validateFlavor(yamlPath: yamlPath, flavorDir: flavorDir);
    expect(errors.any((e) => e.contains('termsUrl')), isTrue);
  });

  test('⑦ theme.dark 键集与 light 不一致 → 报错', () {
    writeFlavor(_validYaml(darkTheme: '{ primary: "#ff5a4a", surface: "#1a1a1a" }'));
    final errors = validateFlavor(yamlPath: yamlPath, flavorDir: flavorDir);
    expect(errors.any((e) => e.contains('theme.dark 键集')), isTrue);
  });

  test('flavor.yaml 不存在 → 报错', () {
    final errors = validateFlavor(
        yamlPath: pJoin(flavorDir, 'nope.yaml'), flavorDir: flavorDir);
    expect(errors.any((e) => e.contains('不存在')), isTrue);
  });

  // 🔴 W0.5 漂移守护：内联 hasSingleFlclashFlag 必须与 SDK ground truth 等价。
  // 见 prepare_flavor.dart 顶部订正注：CLI 不能 import SDK barrel（透传 Flutter），
  // 故内联逻辑；此 parity 测试 import 真 SDK 断言两者对同一批 UA 判定一致。
  group('hasSingleFlclashFlag parity（vs SDK HttpConfig ground truth）', () {
    const cases = <String>[
      'MyClient/0.1.0 flclash', // 单 flag ✅
      'FlClash-XBoard-SDK/1.0', // 单 flag（大小写不敏感）✅
      'no-flag-here', // 0 flag ❌
      'FlClash-MyClient flclash', // 双 flag ❌
      'flclashflclash', // 双 flag 紧邻 ❌
      'FLCLASH', // 单 flag 全大写 ✅
      '', // 空 ❌
    ];

    test('内联逻辑与 SDK HttpConfig.hasSingleFlclashFlag 逐 case 一致', () {
      for (final ua in cases) {
        expect(
          hasSingleFlclashFlag(ua),
          HttpConfig.hasSingleFlclashFlag(ua),
          reason: 'UA "$ua" 判定漂移：内联 vs SDK ground truth 不一致',
        );
      }
    });
  });
}

/// 极简 join（避免 tool/test 依赖 package:path 的 import 解析）。
String pJoin(String a, [String? b, String? c, String? d]) {
  final parts = [a, b, c, d].whereType<String>();
  return parts.join(Platform.pathSeparator);
}
