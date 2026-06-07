/// XbAsyncView 契约测试（四分支 + 优先级 + 错误文案解析）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/xboard/models/xb_domain_error.dart';
import 'package:fl_clash/xboard/widgets/xb_async_view.dart';

Future<void> _pump(
  WidgetTester t, {
  bool loading = false,
  bool retrying = false,
  Object? error,
  VoidCallback? onRetry,
}) async {
  await t.pumpWidget(MaterialApp(
    home: Scaffold(
      body: XbAsyncView(
        loading: loading,
        retrying: retrying,
        error: error,
        onRetry: onRetry ?? () {},
        errorFallback: '加载失败',
        builder: (_) => const Text('DATA', textDirection: TextDirection.ltr),
      ),
    ),
  ));
  await t.pump();
}

void main() {
  testWidgets('data 态：渲染 builder 内容', (t) async {
    await _pump(t);
    expect(find.text('DATA'), findsOneWidget);
  });

  testWidgets('loading 态：spinner，不渲染 data', (t) async {
    await _pump(t, loading: true);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('DATA'), findsNothing);
  });

  testWidgets('retrying 态：显示「正在刷新服务」黄横幅', (t) async {
    await _pump(t, retrying: true);
    expect(find.text('正在刷新服务，请稍候…'), findsOneWidget);
    expect(find.text('DATA'), findsNothing);
  });

  testWidgets('error 态：领域错误经 resolveErrorText 渲染 + 重试按钮', (t) async {
    var retried = 0;
    await _pump(t,
        error: const XbNetwork(XbNetworkKind.unknown, 'x'),
        onRetry: () => retried++);
    // 失败重试块有「重试」按钮。
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('DATA'), findsNothing);
    await t.tap(find.text('重试'));
    expect(retried, 1, reason: 'onRetry 被调用');
  });

  testWidgets('优先级：retrying 压过 loading', (t) async {
    await _pump(t, loading: true, retrying: true);
    // retrying 横幅在场（注：横幅自身含小 spinner，故不以 spinner 有无判断）。
    expect(find.text('正在刷新服务，请稍候…'), findsOneWidget);
    expect(find.text('DATA'), findsNothing);
  });

  testWidgets('优先级：retrying 压过 error', (t) async {
    await _pump(t,
        retrying: true, error: const XbNetwork(XbNetworkKind.unknown, 'x'));
    expect(find.text('正在刷新服务，请稍候…'), findsOneWidget);
    expect(find.text('重试'), findsNothing);
  });

  testWidgets('优先级：loading 压过 error', (t) async {
    await _pump(t,
        loading: true, error: const XbNetwork(XbNetworkKind.unknown, 'x'));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('重试'), findsNothing);
  });

  testWidgets('非领域错误 → 用 fallback 文案', (t) async {
    await _pump(t, error: Exception('raw'));
    expect(find.text('加载失败'), findsOneWidget);
  });
}
