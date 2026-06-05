/// W3.3 — XbLineCard 单测（连接态线路名 / 未连接引导 / 点击回调）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart' show Group, Proxy, ProxiesTabState;
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/shell/tabs/home/xb_line_card.dart';

ProxiesTabState _tab(String? selected) => ProxiesTabState(
      groups: [
        Group(
          type: GroupType.Selector,
          name: '智能优选',
          all: [const Proxy(name: '香港01', type: 'ss')],
          now: selected,
        ),
      ],
      currentGroupName: '智能优选',
      proxyCardType: ProxyCardType.expand,
      columns: 2,
    );

Future<void> pumpCard(
  WidgetTester tester, {
  required bool isStart,
  String? selected,
  VoidCallback? onTap,
}) async {
  final container = ProviderContainer(
    overrides: [
      isStartProvider.overrideWith((ref) => isStart),
      proxiesTabStateProvider.overrideWith((ref) => _tab(selected)),
    ],
  );
  addTearDown(container.dispose);
  container.read(bootstrapReadyProvider.notifier).set(true);
  container.read(coreStatusProvider.notifier).value =
      isStart ? CoreStatus.connected : CoreStatus.disconnected;
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(body: XbLineCard(onTapToNodes: onTap)),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('已连接 → 显示当前线路名', (tester) async {
    await pumpCard(tester, isStart: true, selected: '香港01');
    expect(find.text('香港01'), findsOneWidget);
    expect(find.text('当前线路'), findsOneWidget);
  });

  testWidgets('未连接 → 连接后自动优选', (tester) async {
    await pumpCard(tester, isStart: false);
    expect(find.text('未选择线路'), findsOneWidget);
    expect(find.text('连接后自动优选'), findsOneWidget);
  });

  testWidgets('点击 → 触发切节点 Tab 回调', (tester) async {
    var tapped = false;
    await pumpCard(tester, isStart: true, selected: '香港01',
        onTap: () => tapped = true);
    await tester.tap(find.byType(XbLineCard));
    expect(tapped, isTrue);
  });
}
