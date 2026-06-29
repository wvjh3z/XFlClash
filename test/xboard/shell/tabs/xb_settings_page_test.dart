/// 形态 A 设置页单测：分组 + 全部选项齐全（复用 ToolsView 选项，原型风格）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/xboard/shell/tabs/mine/xb_settings_page.dart';

void main() {
  testWidgets('设置页渲染：更多/设置两组 + 全部选项（其他组/语言已隐藏）', (tester) async {
    // 设置列表较长，拉高测试视口让全部项一屏内 build（避免 ListView 懒加载漏项）。
    tester.view.physicalSize = const Size(1080, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: XbSettingsPage()),
      ),
    );
    await tester.pump();

    // 分组标题：更多 / 设置（「其他」组用户 2026-06-29 全平台隐藏）。
    expect(find.text('设置'), findsWidgets); // AppBar 标题 + 分组
    expect(find.text('更多'), findsOneWidget);
    // 「其他」组（免责声明 / 关于）已隐藏。
    expect(find.text('其他'), findsNothing);
    expect(find.text('免责声明'), findsNothing);
    expect(find.text('关于'), findsNothing);

    // 选项（复用 ToolsView 全部能力，文案对齐原型/FlClash；语言默认隐藏强制简中）。
    for (final label in const [
      '主题',
      '备份与恢复',
      '基本配置',
      '进阶配置',
      '应用程序',
      '请求',
      '连接',
      '资源',
    ]) {
      expect(find.text(label), findsOneWidget, reason: '缺选项: $label');
    }
  });
}
