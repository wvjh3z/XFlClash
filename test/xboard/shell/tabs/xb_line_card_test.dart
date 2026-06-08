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
  testWidgets('已连接 → 上行节点名 + 下行「当前分组：X」', (tester) async {
    await pumpCard(tester, isStart: true, selected: '香港01');
    expect(find.text('香港01'), findsOneWidget);
    expect(find.text('当前分组：智能优选'), findsOneWidget);
  });

  testWidgets('已连接 → 沿 now 链下钻显示叶子节点 + 其所属分组（主组→子组→节点）',
      (tester) async {
    final container = ProviderContainer(
      overrides: [
        isStartProvider.overrideWith((ref) => true),
        proxiesTabStateProvider.overrideWith(
          (ref) => ProxiesTabState(
            currentGroupName: '智能优选',
            proxyCardType: ProxyCardType.expand,
            columns: 2,
            groups: [
              // 主组指向子组「香港」。
              Group(
                type: GroupType.Selector,
                name: '智能优选',
                now: '香港',
                all: const [Proxy(name: '香港', type: 'Selector')],
              ),
              // 子组「香港」指向叶子节点。
              Group(
                type: GroupType.Selector,
                name: '香港',
                now: '🇭🇰 香港 BGP 02',
                all: const [Proxy(name: '🇭🇰 香港 BGP 02', type: 'ss')],
              ),
            ],
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(bootstrapReadyProvider.notifier).set(true);
    container.read(coreStatusProvider.notifier).value = CoreStatus.connected;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: XbLineCard())),
      ),
    );
    await tester.pump();
    // 上行：下钻到叶子节点（非子组名「香港」）。
    expect(find.text('🇭🇰 香港 BGP 02'), findsOneWidget);
    // 下行：叶子节点的直接父分组「香港」。
    expect(find.text('当前分组：香港'), findsOneWidget);
  });

  testWidgets('未连接 → 连接后自动优选', (tester) async {
    await pumpCard(tester, isStart: false);
    expect(find.text('未选择线路'), findsOneWidget);
    expect(find.text('连接后自动优选'), findsOneWidget);
  });

  testWidgets('未连接但已选节点 → 仍显示节点名 + 当前分组（核心修复）', (tester) async {
    // 用户在节点页选了节点但未连接：首页应显示已选节点，而非「未选择线路」。
    await pumpCard(tester, isStart: false, selected: '香港01');
    expect(find.text('香港01'), findsOneWidget);
    expect(find.text('当前分组：智能优选'), findsOneWidget);
    expect(find.text('未选择线路'), findsNothing);
  });

  testWidgets('点击 → 触发切节点 Tab 回调', (tester) async {
    var tapped = false;
    await pumpCard(tester, isStart: true, selected: '香港01',
        onTap: () => tapped = true);
    await tester.tap(find.byType(XbLineCard));
    expect(tapped, isTrue);
  });
}
