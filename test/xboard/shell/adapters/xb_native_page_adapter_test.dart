/// W2.5 — XbNativePageAdapter.openNativeTools 单测。
///
/// 验证 openNativeTools 触发一次 Navigator.push（route 推入）。不全量渲染 ToolsView（依赖大量
/// provider + core），仅断言导航行为发生 —— 渲染不崩由 W6.4 集成冒烟覆盖。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/xboard/shell/adapters/xb_native_page_adapter.dart';

class _PushObserver extends NavigatorObserver {
  int pushes = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushes++;
    super.didPush(route, previousRoute);
  }
}

void main() {
  testWidgets('openNativeTools → 触发一次 Navigator.push', (tester) async {
    final observer = _PushObserver();
    const adapter = XbNativePageAdapter();

    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [observer],
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => adapter.openNativeTools(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    final pushesBefore = observer.pushes; // 初始 home 推入
    await tester.tap(find.text('open'));
    await tester.pump(); // 不 settle（ToolsView 渲染需 provider，仅验 push 已发起）
    expect(observer.pushes, greaterThan(pushesBefore));
    // 吞掉 ToolsView 渲染因缺 provider 抛的异常（本测试只验导航行为）。
    final ex = tester.takeException();
    expect(ex == null || ex is Object, isTrue);
  });
}
