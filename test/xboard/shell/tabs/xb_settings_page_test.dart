/// 形态 A 设置页单测：分组 + 全部选项齐全（复用 ToolsView 选项，原型风格）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/xboard/shell/tabs/mine/xb_settings_page.dart';

void main() {
  testWidgets('设置页渲染：设置/其他两组 + 全部选项', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: XbSettingsPage()),
      ),
    );
    await tester.pump();

    // 分组标题。
    expect(find.text('设置'), findsWidgets); // AppBar 标题 + 分组
    expect(find.text('其他'), findsOneWidget);

    // 选项（复用 ToolsView 全部能力，原型风格）。
    for (final label in const [
      '语言',
      '主题',
      '备份与恢复',
      '基础配置',
      '高级配置',
      '应用设置',
      '免责声明',
      '关于',
    ]) {
      expect(find.text(label), findsOneWidget, reason: '缺选项: $label');
    }
  });
}
