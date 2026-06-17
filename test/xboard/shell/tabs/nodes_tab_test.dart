/// W4.1·W4.2 — NodesTab 单测（游客 / 空态；populated 留 W6.4 集成冒烟）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart'
    show ProxiesTabState, Group, Proxy;
import 'package:fl_clash/providers/state.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/models/xb_domain_subscription.dart';
import 'package:fl_clash/xboard/providers/user_profile_provider.dart';
import 'package:fl_clash/xboard/shell/tabs/nodes/nodes_tab.dart';

class _FakeAuth extends AuthStateNotifier {
  _FakeAuth(this._initial);
  final AuthState _initial;
  @override
  AuthState build() => _initial;
}

ProxiesTabState _emptyTab() => const ProxiesTabState(
      groups: [],
      currentGroupName: null,
      proxyCardType: ProxyCardType.expand,
      columns: 2,
    );

/// 多分组 + 长节点名（验证顶部 tab 只显示选中组 + 名字不截断）。
ProxiesTabState _multiTab() => const ProxiesTabState(
      groups: [
        Group(
          type: GroupType.URLTest,
          name: '智能优选',
          now: '🇭🇰 香港 IEPL 专线 01 — 超长名字测试不被截断显示完整',
          all: [
            Proxy(
                name: '🇭🇰 香港 IEPL 专线 01 — 超长名字测试不被截断显示完整',
                type: 'ss'),
            Proxy(name: '🇯🇵 东京 IEPL 02', type: 'vmess'),
          ],
        ),
        Group(
          type: GroupType.Selector,
          name: '香港',
          now: '🇭🇰 香港 BGP 02',
          all: [Proxy(name: '🇭🇰 香港 BGP 02', type: 'ss')],
        ),
      ],
      currentGroupName: '智能优选',
      proxyCardType: ProxyCardType.expand,
      columns: 2,
    );

Future<void> pumpNodes(
  WidgetTester tester, {
  required AuthState auth,
  ProxiesTabState? tab,
  String? targetGroup,
  String? targetNode,
  int targetNonce = 0,
  List<Override> extraOverrides = const [],
}) async {
  final state = tab ?? _emptyTab();
  // 隔离 FlClash 内核 provider：给每组选中态 + 每节点延迟固定值，避免触达真实 DB。
  final overrides = [
    authStateProvider.overrideWith(() => _FakeAuth(auth)),
    proxiesTabStateProvider.overrideWith((ref) => state),
    ...extraOverrides,
  ];
  for (final g in state.groups) {
    overrides.add(selectedProxyNameProvider(g.name).overrideWithValue(g.now));
    overrides.add(proxyNameProvider(g.name).overrideWithValue(null));
    for (final p in g.all) {
      overrides.add(
        delayProvider(proxyName: p.name, testUrl: g.testUrl)
            .overrideWithValue(48),
      );
    }
  }
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        home: Scaffold(
          body: NodesTab(
            targetGroup: targetGroup,
            targetNode: targetNode,
            targetNonce: targetNonce,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('游客态 → 登录引导（R4.7）', (tester) async {
    await pumpNodes(tester, auth: AuthState.unauthenticated);
    expect(find.text('登录后查看专属线路'), findsOneWidget);
    expect(find.text('立即登录'), findsOneWidget);
  });

  testWidgets('已登录 + 无分组 → 空态引导续费（R4.6）', (tester) async {
    await pumpNodes(tester, auth: AuthState.authenticated);
    expect(find.text('当前无可用线路'), findsOneWidget);
    // 按钮文案：续费 / 购买（用户可能无套餐需新购）。
    expect(find.text('前往续费 / 购买'), findsOneWidget);
    // 空态内不再放「刷新重试」（右上角已有「刷新节点」）。
    expect(find.text('刷新重试'), findsNothing);
    // 空态顶部保留「刷新节点」按钮（原型 nodes('empty') abar 一致，触发重拉订阅）。
    expect(find.text('刷新节点'), findsOneWidget);
  });

  testWidgets('多分组 → 顶部 tab 列全部分组名，只显示选中组节点', (tester) async {
    await pumpNodes(tester, auth: AuthState.authenticated, tab: _multiTab());
    // 顶部 tab 两个分组名都在。
    expect(find.text('智能优选'), findsWidgets);
    expect(find.text('香港'), findsWidgets);
    // 默认选中「智能优选」→ 只显示该组节点，不显示「香港」组的节点。
    expect(find.text('🇯🇵 东京 IEPL 02'), findsOneWidget);
    expect(find.text('🇭🇰 香港 BGP 02'), findsNothing);
    // 长节点名渲染不抛溢出（pumpAndSettle 无异常即通过）。
    await tester.pumpAndSettle();
  });

  testWidgets('点顶部 tab 切换分组 → 显示该组节点', (tester) async {
    await pumpNodes(tester, auth: AuthState.authenticated, tab: _multiTab());
    // 点「香港」tab。
    await tester.tap(find.text('香港').first);
    await tester.pumpAndSettle();
    expect(find.text('🇭🇰 香港 BGP 02'), findsOneWidget);
    // 切走后不再显示「智能优选」组的节点。
    expect(find.text('🇯🇵 东京 IEPL 02'), findsNothing);
  });

  testWidgets('首页定位：targetGroup 指定 → 打开即切到该分组 + 选中节点行可见', (tester) async {
    // 默认选中组是「智能优选」，但定位目标是「香港」组 → 应自动切到香港组。
    await pumpNodes(
      tester,
      auth: AuthState.authenticated,
      tab: _multiTab(),
      targetGroup: '香港',
      targetNode: '🇭🇰 香港 BGP 02',
      targetNonce: 1,
    );
    await tester.pumpAndSettle();
    // 切到香港组 → 显示其节点（选中行可见），不显示智能优选组节点。
    expect(find.text('🇭🇰 香港 BGP 02'), findsOneWidget);
    expect(find.text('🇯🇵 东京 IEPL 02'), findsNothing);
  });

  testWidgets('套餐已过期（仍有分组缓存）→ 清空节点 + 过期空态（不展示缓存节点）',
      (tester) async {
    // 用户有套餐有流量（planId+totalBytes 齐全），但 expiredAt 已过 → build() 应以过期
    // 为先：清空节点、显示「当前无可用线路」空态，而非渲染缓存的分组节点。
    final expired = XbDomainSubscription(
      email: 'a@b.com',
      uuid: 'x',
      planId: 7,
      planName: '标准套餐',
      totalBytes: 100 * 1024 * 1024 * 1024,
      usedBytes: 1024,
      expiredAt: DateTime.now().subtract(const Duration(days: 1)),
    );
    await pumpNodes(
      tester,
      auth: AuthState.authenticated,
      tab: _multiTab(),
      extraOverrides: [
        userProfileProvider.overrideWith((ref) async => expired),
      ],
    );
    await tester.pumpAndSettle();
    // 过期空态可见，缓存节点被清空。
    expect(find.text('当前无可用线路'), findsOneWidget);
    expect(find.text('🇯🇵 东京 IEPL 02'), findsNothing);
    // 顶部仍保留「刷新节点」。
    expect(find.text('刷新节点'), findsOneWidget);
  });
}
