// inject_desktop_brand 纯变换契约测试（真实文件片段 + 幂等）。
// 跑：dart test tool/test/inject_desktop_brand_test.dart

import 'package:test/test.dart';

import '../inject_desktop_brand.dart';

void main() {
  const app = 'OmoFly';

  test('Windows 窗口标题', () {
    const src = '  if (!window.Create(L"FlClash", origin, size)) {';
    final out = injectWindowsTitle(src, app);
    expect(out, contains('L"OmoFly"'));
    expect(out, isNot(contains('FlClash')));
    expect(injectWindowsTitle(out, app), out); // 幂等
  });

  test('Windows Runner.rc FileDescription（不动 ProductName/InternalName）', () {
    const src = '            VALUE "FileDescription", "FlClash" "\\0"\n'
        '            VALUE "ProductName", "clash" "\\0"\n'
        '            VALUE "InternalName", "clash" "\\0"';
    final out = injectWindowsRc(src, app);
    expect(out, contains('"FileDescription", "OmoFly"'));
    expect(out, contains('"ProductName", "clash"')); // 不动
    expect(out, contains('"InternalName", "clash"')); // 不动
    expect(injectWindowsRc(out, app), out);
  });

  test('Linux 窗口标题（header_bar + window 两处）', () {
    const src = '    gtk_header_bar_set_title(header_bar, "FlClash");\n'
        '    gtk_window_set_title(window, "FlClash");';
    final out = injectLinuxTitle(src, app);
    expect('OmoFly'.allMatches(out).length, 2);
    expect(out, isNot(contains('"FlClash"')));
    expect(injectLinuxTitle(out, app), out);
  });

  test('macOS PRODUCT_NAME', () {
    const src = '// comment\nPRODUCT_NAME = FlClash\n'
        'PRODUCT_BUNDLE_IDENTIFIER = com.follow.clash';
    final out = injectMacProductName(src, app);
    expect(out, contains('PRODUCT_NAME = OmoFly'));
    expect(out, contains('PRODUCT_BUNDLE_IDENTIFIER = com.follow.clash')); // 不动
    expect(injectMacProductName(out, app), out);
  });

  test('macOS Info.plist 定位权限文案（不动 URL scheme flclash）', () {
    const src = '<string>flclash</string>\n'
        '<key>NSLocationWhenInUseUsageDescription</key>\n'
        '<string>FlClash needs location access to detect WiFi network name.</string>';
    final out = injectMacInfoPlist(src, app);
    expect(out, contains('<string>OmoFly needs location access'));
    expect(out, contains('<string>flclash</string>')); // URL scheme 不动
    expect(injectMacInfoPlist(out, app), out);
  });

  test('macOS dmg make_config（title + .app 路径）', () {
    const src = 'title: FlClash\ncontents:\n  - type: file\n    path: FlClash.app\n';
    final out = injectDmgMakeConfig(src, app);
    expect(out, contains('title: OmoFly'));
    expect(out, contains('path: OmoFly.app'));
    expect(out, isNot(contains('FlClash')));
    expect(injectDmgMakeConfig(out, app), out);
  });

  test('通用 make_config 显示名（display_name/generic_name/keywords 外）', () {
    const src = 'display_name: FlClash\napp_name: MyClient\n'
        'generic_name: FlClash\npublisher: chen08209\napp_id: ABC-123\n';
    final out = injectMakeConfigNames(src, app);
    expect(out, contains('display_name: OmoFly'));
    expect(out, contains('app_name: OmoFly')); // 从 MyClient 也统一过来
    expect(out, contains('generic_name: OmoFly'));
    expect(out, contains('publisher: chen08209')); // 不动
    expect(out, contains('app_id: ABC-123')); // 不动
    expect(injectMakeConfigNames(out, app), out);
  });

  test('flutter_launcher_icons.yaml 生成（image_path 指向品牌 png / 仅桌面）', () {
    const png = 'flavors/brand_a/assets/icons/brand_a.png';
    final out = buildLauncherIconsYaml(png);
    expect(out, contains('image_path: "$png"'));
    expect(out, contains('android: false')); // Android 走 prepare_flavor
    expect(out, contains('ios: false'));
    expect(out, contains('windows:'));
    expect(out, contains('icon_size: 256'));
    expect(out, contains('macos:'));
  });
}
