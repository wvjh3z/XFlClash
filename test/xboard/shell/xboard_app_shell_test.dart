/// W1.1 — XboardAppShell 三 Tab 骨架 widget test。
///
/// 覆盖：默认渲染首页 / 底栏三项 / 切 Tab 生效 / IndexedStack 保活（三 Tab 子树常驻）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/xboard/shell/xboard_app_shell.dart';

void main() {
  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: XboardAppShell()),
      ),
    );
  }

  testWidgets('默认渲染首页 Tab + 底栏三项', (tester) async {
    await pump(tester);
    // 底栏三项 label。
    expect(find.text('首页'), findsWidgets);
    expect(find.text('节点'), findsWidgets);
    expect(find.text('我的'), findsWidgets);
    // 默认 index=0 → 首页占位图标可见。
    expect(find.byIcon(Icons.home), findsWidgets);
  });

  testWidgets('点击底栏切换到节点 Tab', (tester) async {
    await pump(tester);
    await tester.tap(find.text('节点'));
    await tester.pumpAndSettle();
    final stack = tester.widget<IndexedStack>(find.byType(IndexedStack));
    expect(stack.index, 1);
  });

  testWidgets('IndexedStack 保活：三 Tab 子树同时在树上', (tester) async {
    await pump(tester);
    // IndexedStack 始终把所有 children 挂在树上（仅切换可见），保证保活。
    final stack = tester.widget<IndexedStack>(find.byType(IndexedStack));
    expect(stack.children.length, 3);
  });
}
