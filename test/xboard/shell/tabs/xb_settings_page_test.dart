/// 形态 A 设置页单测：分组 + 全部选项齐全（复用 ToolsView 选项，原型风格）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/xboard/shell/tabs/mine/xb_settings_page.dart';

void main() {
  testWidgets('设置页渲染：设置/数据与诊断/其他三组 + 全部选项', (tester) async {
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

    // 分组标题。
    expect(find.text('设置'), findsWidgets); // AppBar 标题 + 分组
    expect(find.text('数据与诊断'), findsOneWidget);
    expect(find.text('其他'), findsOneWidget);

    // 选项（复用 ToolsView 全部能力，原型风格）。
    for (final label in const [
      '语言',
      '主题',
      '备份与恢复',
      '基础配置',
      '高级配置',
      '应用设置',
      '请求',
      '连接',
      '资源',
      '免责声明',
      '关于',
    ]) {
      expect(find.text(label), findsOneWidget, reason: '缺选项: $label');
    }
  });
}
