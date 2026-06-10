/// 框架化骨架屏 XbSkeletonView + XbAsyncView.skeleton 契约测试。
///
/// 锁定：list/detail 两形态可渲染、不溢出；XbAsyncView 传 skeleton 时 loading 分支渲染骨架。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/xboard/widgets/xb_async_view.dart';
import 'package:fl_clash/xboard/widgets/xb_components.dart';
import 'package:fl_clash/xboard/widgets/xb_theme.dart' show buildXbTheme;

Widget _host(Widget child) => MaterialApp(
      theme: buildXbTheme(
          brandColor: const Color(0xFFD92E1A), brightness: Brightness.light),
      home: Scaffold(body: child),
    );

void main() {
  testWidgets('list 形态：渲染 N 张骨架卡，无溢出', (tester) async {
    await tester.pumpWidget(
        _host(const XbSkeletonView(kind: XbSkeletonKind.list, count: 4)));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(XbSkeletonView), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('detail 形态：渲染信息卡骨架，无溢出', (tester) async {
    await tester.pumpWidget(
        _host(const XbSkeletonView(kind: XbSkeletonKind.detail)));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(XbSkeletonView), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('detail 形态在窄屏 + 大字号不溢出', (tester) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildXbTheme(
            brandColor: const Color(0xFFD92E1A),
            brightness: Brightness.light),
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2.0)),
          child: const Scaffold(
              body: XbSkeletonView(kind: XbSkeletonKind.detail)),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
  });

  testWidgets('XbAsyncView：loading + skeleton → 渲染骨架（非默认 spinner）',
      (tester) async {
    await tester.pumpWidget(_host(
      XbAsyncView(
        loading: true,
        error: null,
        skeleton: XbSkeletonKind.list,
        onRetry: () {},
        builder: (_) => const Text('data'),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(XbSkeletonView), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('data'), findsNothing);
  });

  testWidgets('XbAsyncView：loading 但无 skeleton → 默认 spinner', (tester) async {
    await tester.pumpWidget(_host(
      XbAsyncView(
        loading: true,
        error: null,
        onRetry: () {},
        builder: (_) => const Text('data'),
      ),
    ));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(XbSkeletonView), findsNothing);
  });
}
