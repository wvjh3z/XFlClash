/// W1.3 — XbBottomBar 自定义底栏 widget test。
///
/// 覆盖：三项渲染 / 点击回调 index / 选中态主题色。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/xboard/shell/widgets/xb_bottom_bar.dart';

void main() {
  Future<void> pump(
    WidgetTester tester, {
    required int currentIndex,
    required ValueChanged<int> onTap,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          bottomNavigationBar:
              XbBottomBar(currentIndex: currentIndex, onTap: onTap),
        ),
      ),
    );
  }

  testWidgets('渲染三项（首页/节点/我的）', (tester) async {
    await pump(tester, currentIndex: 0, onTap: (_) {});
    expect(find.text('首页'), findsOneWidget);
    expect(find.text('节点'), findsOneWidget);
    expect(find.text('我的'), findsOneWidget);
  });

  testWidgets('点击节点 → onTap(1)', (tester) async {
    int? tapped;
    await pump(tester, currentIndex: 0, onTap: (i) => tapped = i);
    await tester.tap(find.text('节点'));
    expect(tapped, 1);
  });

  testWidgets('选中项图标用主题色 primary', (tester) async {
    await pump(tester, currentIndex: 2, onTap: (_) {});
    // 选中「我的」→ person 实心图标，颜色 = primary。
    final icon = tester.widget<Icon>(find.byIcon(Icons.person));
    final ctx = tester.element(find.byIcon(Icons.person));
    expect(icon.color, Theme.of(ctx).colorScheme.primary);
  });
}
