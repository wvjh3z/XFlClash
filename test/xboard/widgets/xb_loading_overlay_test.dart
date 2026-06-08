/// xbRunWithLoading 全局加载遮罩：显示 / 阻断重入 / 完成关闭 / 异常关闭。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/xboard/widgets/xb_loading_overlay.dart';

Widget _host(void Function(BuildContext) onReady) {
  return MaterialApp(
    home: Scaffold(
      body: Builder(builder: (ctx) {
        onReady(ctx);
        return const SizedBox();
      }),
    ),
  );
}

void main() {
  testWidgets('显示遮罩 + 文案，action 完成后关闭', (t) async {
    late BuildContext ctx;
    await t.pumpWidget(_host((c) => ctx = c));
    final gate = Completer<int>();
    final fut = xbRunWithLoading(ctx, () => gate.future, message: '加载中…');
    await t.pump(); // 弹出 dialog
    expect(find.text('加载中…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    gate.complete(42);
    final r = await fut;
    await t.pumpAndSettle();
    expect(r, 42);
    expect(find.text('加载中…'), findsNothing); // 已关闭
  });

  testWidgets('重入：遮罩显示期间再调，不叠加第二层遮罩', (t) async {
    late BuildContext ctx;
    await t.pumpWidget(_host((c) => ctx = c));
    final gate = Completer<void>();
    final f1 = xbRunWithLoading(ctx, () => gate.future);
    await t.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    // 第二次调用：不再弹新遮罩（仍只有一个）。
    var ran = false;
    final f2 = xbRunWithLoading(ctx, () async {
      ran = true;
    });
    await t.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget,
        reason: '不叠加第二层遮罩');
    expect(ran, isTrue, reason: '重入时 action 仍执行（只是不再弹遮罩）');
    gate.complete();
    await f1;
    await f2;
    await t.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('action 抛异常 → rethrow，遮罩仍关闭', (t) async {
    late BuildContext ctx;
    await t.pumpWidget(_host((c) => ctx = c));
    Object? caught;
    try {
      await xbRunWithLoading(ctx, () async => throw StateError('boom'));
    } catch (e) {
      caught = e;
    }
    await t.pumpAndSettle();
    expect(caught, isA<StateError>());
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}
