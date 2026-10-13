/// 账号切换后旧刷新不得污染新会话的节点提示、账号信息或刷新冷却。
library;

import 'dart:async';

import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart'
    show Group, PatchClashConfig, ProxiesTabState, Proxy;
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:fl_clash/xboard/config/xboard_config.dart';
import 'package:fl_clash/xboard/models/xb_domain_error.dart';
import 'package:fl_clash/xboard/models/xb_domain_subscription.dart';
import 'package:fl_clash/xboard/models/xb_invite.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/providers/invite_provider.dart';
import 'package:fl_clash/xboard/providers/user_profile_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/sdk/xboard_service.dart';
import 'package:fl_clash/xboard/services/xboard_subscription_service.dart';
import 'package:fl_clash/xboard/shell/tabs/mine/mine_tab.dart';
import 'package:fl_clash/xboard/shell/tabs/nodes/nodes_tab.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockService extends Mock implements XboardService {}

class _MockSync extends Mock implements XboardSubscriptionService {}

class _Authenticated extends AuthStateNotifier {
  @override
  AuthState build() => AuthState.authenticated;
}

class _ProfileFixture {
  String account = 'A';
  int loads = 0;

  XbDomainSubscription get data => XbDomainSubscription(
    email: 'account-$account@example.invalid',
    uuid: 'account-$account',
    planName: '账号 $account 套餐',
    planId: 1,
    totalBytes: 100 * 1024 * 1024 * 1024,
    usedBytes: 10 * 1024 * 1024 * 1024,
  );
}

const _group = Group(
  type: GroupType.Selector,
  name: '手选线路',
  now: '可用测试节点',
  all: [Proxy(name: '可用测试节点', type: 'ss')],
);

Future<ProviderContainer> _pumpTab(
  WidgetTester tester, {
  required bool nodes,
  required _ProfileFixture profile,
  XboardService? service,
  XboardSubscriptionService? sync,
}) async {
  // 节点用移动布局，账号用桌面布局，两种真实刷新入口都覆盖。
  tester.view.physicalSize = nodes
      ? const Size(390, 800)
      : const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  XboardConfig.bind(
    const XboardConfig(
      subscribeUserAgent: 'ui-test',
      devApiEndpoint: 'https://example.invalid',
      devSubscriptionEndpoint: 'https://example.invalid',
      debug: false,
      kIsTest: true,
      formA: true,
    ),
  );
  addTearDown(XboardConfig.resetForTest);
  final container = ProviderContainer(
    overrides: [
      authStateProvider.overrideWith(_Authenticated.new),
      if (service != null) xboardServiceProvider.overrideWithValue(service),
      if (sync != null) subscriptionServiceProvider.overrideWithValue(sync),
      userProfileProvider.overrideWith((ref) async {
        profile.loads++;
        return profile.data;
      }),
      inviteInfoProvider.overrideWith(
        (ref) async => const XbInviteInfo(
          code: 'test-code',
          registeredCount: 0,
          pendingYuan: 0,
          totalYuan: 0,
          commissionRate: 20,
          commissionBalanceYuan: 0,
          accountBalanceYuan: 0,
        ),
      ),
      proxiesTabStateProvider.overrideWith(
        (ref) => const ProxiesTabState(
          groups: [_group],
          currentGroupName: '手选线路',
          proxyCardType: ProxyCardType.expand,
          columns: 2,
        ),
      ),
      patchClashConfigProvider.overrideWithBuild(
        (ref, _) => const PatchClashConfig(mode: Mode.rule),
      ),
      selectedProxyNameProvider(_group.name).overrideWithValue(_group.now),
      proxyNameProvider(_group.name).overrideWithValue(null),
      delayProvider(
        proxyName: '可用测试节点',
        testUrl: _group.testUrl,
      ).overrideWithValue(48),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(body: nodes ? const NodesTab() : const MineTab()),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 800));
  return container;
}

Future<void> _switchToB(
  WidgetTester tester,
  ProviderContainer container,
  _ProfileFixture profile, {
  required bool nodes,
}) async {
  final auth = container.read(authStateProvider.notifier);
  auth.markUnauthenticated();
  await tester.pump();
  expect(find.text(nodes ? '登录后查看专属线路' : '登录 / 注册'), findsOneWidget);
  profile.account = 'B';
  container.invalidate(userProfileProvider);
  auth.markAuthenticated();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 800));
}

void main() {
  testWidgets('移动节点：A 刷新晚到过期结果不污染 B 空态、提示或冷却，B 可立即刷新', (tester) async {
    final original = ErrorWidget.builder;
    try {
      final profile = _ProfileFixture();
      final sync = _MockSync();
      final responseA = Completer<XbSyncOutcome>();
      var calls = 0;
      when(() => sync.sync(force: true)).thenAnswer((_) {
        calls++;
        return calls == 1 ? responseA.future : Future.value(XbSyncOutcome.ok);
      });
      final container = await _pumpTab(
        tester,
        nodes: true,
        profile: profile,
        sync: sync,
      );
      await tester.tap(find.text('刷新节点'));
      await tester.pump();
      expect(find.text('正在刷新节点，请稍候…'), findsOneWidget);
      await _switchToB(tester, container, profile, nodes: true);
      responseA.complete(XbSyncOutcome.subscriptionExpired);
      await tester.pump();

      expect(find.text('可用测试节点', findRichText: true), findsOneWidget);
      expect(find.text('当前无可用线路'), findsNothing);
      expect(find.text('套餐已过期，请前往续费 / 购买'), findsNothing);
      expect(find.text('正在刷新节点，请稍候…'), findsNothing);
      expect(find.text('刷新节点'), findsOneWidget);
      expect(find.textContaining(RegExp(r'刷新节点 \d+s')), findsNothing);
      await tester.tap(find.text('刷新节点'));
      await tester.pump();
      expect(calls, 2, reason: 'A 的晚到结果不能给 B 设置 60 秒冷却');
      expect(tester.takeException(), isNull);
    } finally {
      ErrorWidget.builder = original;
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('移动节点：换号清掉 A 已完成刷新留下的过期空态和冷却', (tester) async {
    final original = ErrorWidget.builder;
    try {
      final profile = _ProfileFixture();
      final sync = _MockSync();
      var calls = 0;
      when(() => sync.sync(force: true)).thenAnswer((_) async {
        calls++;
        return calls == 1
            ? XbSyncOutcome.subscriptionExpired
            : XbSyncOutcome.ok;
      });
      final container = await _pumpTab(
        tester,
        nodes: true,
        profile: profile,
        sync: sync,
      );
      await tester.tap(find.text('刷新节点'));
      await tester.pump();
      expect(find.text('当前无可用线路'), findsOneWidget);
      expect(find.textContaining(RegExp(r'刷新节点 \d+s')), findsOneWidget);
      await tester.pump(const Duration(seconds: 4)); // 等 A 的旧提示自行消失。
      await _switchToB(tester, container, profile, nodes: true);

      expect(find.text('可用测试节点', findRichText: true), findsOneWidget);
      expect(find.text('当前无可用线路'), findsNothing);
      expect(find.text('刷新节点'), findsOneWidget);
      await tester.tap(find.text('刷新节点'));
      await tester.pump();
      expect(calls, 2);
      expect(tester.takeException(), isNull);
    } finally {
      ErrorWidget.builder = original;
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('桌面账号：A 刷新晚到不重拉 B 信息或设置冷却，B 可立即刷新', (tester) async {
    final original = ErrorWidget.builder;
    try {
      final profile = _ProfileFixture();
      final service = _MockService();
      final responseA = Completer<XbResult<XbDomainSubscription>>();
      var calls = 0;
      when(service.getSubscription).thenAnswer((_) {
        calls++;
        return calls == 1
            ? responseA.future
            : Future.value(XbResult.success(profile.data));
      });
      final container = await _pumpTab(
        tester,
        nodes: false,
        profile: profile,
        service: service,
      );
      await tester.tap(find.text('刷新信息'));
      await tester.pump();
      expect(find.text('正在刷新服务，请稍候…'), findsOneWidget);
      await _switchToB(tester, container, profile, nodes: false);
      final bLoads = profile.loads;
      responseA.complete(const XbFailure(XbUnauthorized('A 登录已过期')));
      await tester.pump();
      await tester.pump();

      expect(find.text('account-B@example.invalid'), findsOneWidget);
      expect(find.text('A 登录已过期'), findsNothing);
      expect(find.text('正在刷新服务，请稍候…'), findsNothing);
      expect(find.text('刷新信息'), findsOneWidget);
      expect(find.textContaining(RegExp(r'刷新信息 \d+s')), findsNothing);
      expect(profile.loads, bLoads, reason: 'A 的晚到结果不能 invalidate B 的账号信息');
      await tester.tap(find.text('刷新信息'));
      await tester.pump();
      expect(calls, 2);
      expect(tester.takeException(), isNull);
    } finally {
      ErrorWidget.builder = original;
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('桌面账号：换号后不继承 A 已完成刷新的冷却', (tester) async {
    final original = ErrorWidget.builder;
    try {
      final profile = _ProfileFixture();
      final service = _MockService();
      var calls = 0;
      when(service.getSubscription).thenAnswer((_) async {
        calls++;
        return XbResult.success(profile.data);
      });
      final container = await _pumpTab(
        tester,
        nodes: false,
        profile: profile,
        service: service,
      );
      await tester.tap(find.text('刷新信息'));
      await tester.pump();
      expect(find.textContaining(RegExp(r'刷新信息 \d+s')), findsOneWidget);
      await _switchToB(tester, container, profile, nodes: false);

      expect(find.text('account-B@example.invalid'), findsOneWidget);
      expect(find.text('刷新信息'), findsOneWidget);
      await tester.tap(find.text('刷新信息'));
      await tester.pump();
      expect(calls, 2, reason: '退出 A 时清理冷却，B 首次刷新应该立即发起');
      expect(tester.takeException(), isNull);
    } finally {
      ErrorWidget.builder = original;
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });
}
