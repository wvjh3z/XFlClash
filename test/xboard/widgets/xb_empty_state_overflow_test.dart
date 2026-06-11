/// 矮高度（横屏 / 分屏 / 多窗口 / 折叠屏 / 大字体）下整屏空态不溢出 —— 尺寸断言。
///
/// 背景：稳定性测试发现横屏底部溢出 178px。怀疑根因是 `XbEmptyState`（节点页游客引导 /
/// 无可用线路空态）用 `Center > Column`，矮高度放不下 → 底部溢出。本测试用矮视口客观锁定，
/// 修复（套滚动）后回归不复发。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/xboard/widgets/xb_components.dart' show XbEmptyState;
import 'package:fl_clash/xboard/widgets/xb_ui_kit.dart' show XbBrandTheme;

Future<void> pumpAt(WidgetTester tester, Size logical, Widget child) async {
  tester.view.physicalSize = Size(logical.width * 2, logical.height * 2);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: XbBrandTheme(
          brandColor: const Color(0xFFD92E1A),
          child: child,
        ),
      ),
    ),
  );
}

/// 最“高”的空态变体（图标 + 标题 + 多行说明 + 主按钮 + 次链接），节点页无可用线路态用它。
Widget _tallestEmptyState() => const XbEmptyState(
      icon: Icons.cloud_off,
      title: '当前套餐无可用线路',
      description: '套餐可能已到期或未生效，\n续费后线路将自动同步。',
      actionLabel: '前往续费',
      secondaryLabel: '刷新重试',
    );

void main() {
  testWidgets('竖屏正常高度：空态不溢出', (tester) async {
    await pumpAt(tester, const Size(390, 844), _tallestEmptyState());
    expect(tester.takeException(), isNull);
  });

  testWidgets('横屏矮高度(约360dp)：空态不溢出(可滚)', (tester) async {
    await pumpAt(tester, const Size(800, 360), _tallestEmptyState());
    expect(tester.takeException(), isNull,
        reason: '矮高度时整屏空态应可滚动而非底部溢出');
  });

  testWidgets('极矮高度(分屏/多窗口 ~240dp)：空态不溢出', (tester) async {
    await pumpAt(tester, const Size(600, 240), _tallestEmptyState());
    expect(tester.takeException(), isNull);
  });
}
