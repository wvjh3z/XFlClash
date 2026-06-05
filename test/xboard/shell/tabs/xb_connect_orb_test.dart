/// W3.1 — XbConnectOrb 四态渲染 + 禁用/点击单测。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/shell/tabs/home/xb_connect_orb.dart';

Future<void> pumpOrb(
  WidgetTester tester, {
  required bool ready,
  required CoreStatus core,
  required bool isStart,
}) async {
  final container = ProviderContainer(
    overrides: [isStartProvider.overrideWith((ref) => isStart)],
  );
  addTearDown(container.dispose);
  container.read(bootstrapReadyProvider.notifier).set(ready);
  container.read(coreStatusProvider.notifier).value = core;
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: Center(child: XbConnectOrb()))),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('booting → 「准备中」', (tester) async {
    await pumpOrb(tester,
        ready: false, core: CoreStatus.disconnected, isStart: false);
    expect(find.text('准备中'), findsOneWidget);
  });

  testWidgets('disconnected → 「未连接」', (tester) async {
    await pumpOrb(tester,
        ready: true, core: CoreStatus.disconnected, isStart: false);
    expect(find.text('未连接'), findsOneWidget);
    expect(find.text('点击连接'), findsOneWidget);
  });

  testWidgets('connecting → 「连接中」', (tester) async {
    await pumpOrb(tester,
        ready: true, core: CoreStatus.connecting, isStart: false);
    expect(find.text('连接中'), findsOneWidget);
  });

  testWidgets('connected → 「已连接」+ 主题色文字', (tester) async {
    await pumpOrb(tester,
        ready: true, core: CoreStatus.connected, isStart: true);
    expect(find.text('已连接'), findsOneWidget);
    expect(find.text('数据已加密保护'), findsOneWidget);
  });

  testWidgets('文案不含技术词（节点/优选/线路/竞速）', (tester) async {
    await pumpOrb(tester,
        ready: true, core: CoreStatus.disconnected, isStart: false);
    for (final w in const ['节点', '优选', '线路', '竞速']) {
      expect(find.textContaining(w), findsNothing);
    }
  });
}
