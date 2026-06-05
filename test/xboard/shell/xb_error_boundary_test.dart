/// W1.4 — XbErrorBoundary 单 Tab 错误边界 widget test。
///
/// 覆盖：① 正常 child 正常渲染；② 安装友好 builder 后 child 抛异常 → 局部错误卡（含 Tab 名），
/// 不全屏红屏；③ IndexedStack 中一个 Tab 崩，可见 Tab + 底栏仍可用。
///
/// **注意**：Flutter test 框架要求测试结束前还原 `ErrorWidget.builder`（tearDown 太晚），
/// 故每个会改 builder 的测试在 body 末尾手动还原；并用 `tester.takeException()` 吞掉
/// 预期的构建异常（否则框架判 test 失败）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/xboard/shell/widgets/xb_bottom_bar.dart';
import 'package:fl_clash/xboard/shell/widgets/xb_error_boundary.dart';

/// 构建期必抛的测试 widget。
class _Boom extends StatelessWidget {
  const _Boom();

  @override
  Widget build(BuildContext context) => throw StateError('boom');
}

void main() {
  testWidgets('正常 child 正常渲染（不改全局 builder）', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: XbErrorBoundary(label: '首页', child: Text('OK_CONTENT')),
        ),
      ),
    );
    expect(find.text('OK_CONTENT'), findsOneWidget);
  });

  testWidgets('安装友好 builder 后 child 抛异常 → 局部错误卡（含 Tab 名）', (tester) async {
    final original = XbErrorBoundary.install();
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: XbErrorBoundary(label: '节点', child: _Boom()),
        ),
      ),
    );
    // 显示局部错误卡（带 Tab 名），而非全屏红屏。
    expect(find.text('「节点」出错了'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    tester.takeException(); // 吞掉预期的 StateError('boom')
    ErrorWidget.builder = original; // body 末尾还原（框架要求）
  });

  testWidgets('一个 Tab 崩，可见 Tab + 底栏仍可用', (tester) async {
    final original = XbErrorBoundary.install();
    var tappedNode = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: const IndexedStack(
            index: 0,
            children: [
              // index 0 可见：正常 Tab。
              XbErrorBoundary(label: '首页', child: Text('HOME_OK')),
              // index 1 隐藏但仍构建：崩溃 Tab，不能波及上面。
              XbErrorBoundary(label: '节点', child: _Boom()),
            ],
          ),
          bottomNavigationBar: XbBottomBar(
            currentIndex: 0,
            onTap: (i) {
              if (i == 1) tappedNode = true;
            },
          ),
        ),
      ),
    );
    // 可见 Tab 正常。
    expect(find.text('HOME_OK'), findsOneWidget);
    // 隐藏的崩溃 Tab 被本地错误卡兜住（IndexedStack offstage slot 仍在树上）。
    expect(find.text('「节点」出错了', skipOffstage: false), findsOneWidget);
    // 底栏仍可点。
    await tester.tap(find.text('节点'));
    expect(tappedNode, isTrue);
    tester.takeException();
    ErrorWidget.builder = original;
  });
}
