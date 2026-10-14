/// 下拉手势接到既有按钮动作：同页防重与 60 秒冷却、游客及会话边界。
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

class _Auth extends AuthStateNotifier {
  _Auth(this.initial);
  final AuthState initial;

  @override
  AuthState build() => initial;
}

enum _Page { mine, nodes, both, pageView }

enum _Nodes { populated, empty, expired, exhausted }

const _group = Group(
  type: GroupType.Selector,
  name: '手选线路',
  now: '可用测试节点',
  all: [Proxy(name: '可用测试节点', type: 'ss')],
);

class _Fixture {
  _Fixture({this.nodeContent = _Nodes.populated}) {
    when(service.getSubscription).thenAnswer((_) {
      accountCalls++;
      return accountResponse?.future ?? Future.value(XbResult.success(data));
    });
    when(() => sync.sync(force: true)).thenAnswer((_) {
      syncCalls++;
      return syncResponse?.future ?? Future.value(XbSyncOutcome.ok);
    });
  }

  final _Nodes nodeContent;
  final service = _MockService();
  final sync = _MockSync();
  Completer<XbResult<XbDomainSubscription>>? accountResponse;
  Completer<XbSyncOutcome>? syncResponse;
  int accountCalls = 0;
  int syncCalls = 0;
  int profileLoads = 0;
  String account = 'A';
  late ProviderContainer container;

  XbDomainSubscription get data => XbDomainSubscription(
    email: 'account-$account@example.invalid',
    uuid: 'account-$account',
    planName: '测试套餐',
    planId: 1,
    totalBytes: 100 * 1024 * 1024 * 1024,
    usedBytes:
        (nodeContent == _Nodes.exhausted ? 100 : 10) * 1024 * 1024 * 1024,
    expiredAt: nodeContent == _Nodes.expired ? DateTime(2020) : null,
  );
}

Future<_Fixture> _pump(
  WidgetTester tester, {
  required _Page page,
  double width = 390,
  bool guest = false,
  _Nodes nodes = _Nodes.populated,
  _Fixture? fixture,
}) async {
  final originalErrorBuilder = ErrorWidget.builder;
  final f = fixture ?? _Fixture(nodeContent: nodes);
  tester.view.physicalSize = Size(width, 1000);
  tester.view.devicePixelRatio = 1;
  XboardConfig.bind(
    const XboardConfig(
      subscribeUserAgent: 'pull-refresh-test',
      devApiEndpoint: 'https://example.invalid',
      devSubscriptionEndpoint: 'https://example.invalid',
      debug: false,
      kIsTest: true,
      formA: true,
    ),
  );
  f.container = ProviderContainer(
    overrides: [
      authStateProvider.overrideWith(
        () =>
            _Auth(guest ? AuthState.unauthenticated : AuthState.authenticated),
      ),
      xboardServiceProvider.overrideWithValue(f.service),
      subscriptionServiceProvider.overrideWithValue(f.sync),
      userProfileProvider.overrideWith((ref) async {
        f.profileLoads++;
        return f.data;
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
        (ref) => ProxiesTabState(
          groups: f.nodeContent == _Nodes.empty ? const [] : const [_group],
          currentGroupName: _group.name,
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
  addTearDown(() async {
    ErrorWidget.builder = originalErrorBuilder;
    await tester.pumpWidget(const SizedBox.shrink());
    f.container.dispose();
    XboardConfig.resetForTest();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  final Widget body = switch (page) {
    _Page.mine => const MineTab(),
    _Page.nodes => const NodesTab(),
    _Page.both => const Row(
      children: [
        Expanded(child: MineTab()),
        Expanded(child: NodesTab()),
      ],
    ),
    _Page.pageView => PageView(children: const [NodesTab(), MineTab()]),
  };
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: f.container,
      child: MaterialApp(home: Scaffold(body: body)),
    ),
  );
  await _finishAnimations(tester);
  return f;
}

Finder _tab(bool nodes) => find.byType(nodes ? NodesTab : MineTab);

Finder _inside(bool nodes, Finder child) =>
    find.descendant(of: _tab(nodes), matching: child);

Finder _cooldown(bool nodes) => _inside(
  nodes,
  find.textContaining(RegExp(nodes ? r'刷新节点 \d+s' : r'刷新信息 \d+s')),
);

Future<void> _pull(WidgetTester tester, {required bool nodes}) async {
  final indicator = _inside(nodes, find.byType(RefreshIndicator));
  expect(indicator, findsOneWidget);
  final scrollable = find.descendant(
    of: indicator,
    matching: find.byWidgetPredicate(
      (w) =>
          w is Scrollable &&
          (w.axisDirection == AxisDirection.down ||
              w.axisDirection == AxisDirection.up),
    ),
  );
  expect(scrollable, findsOneWidget);
  // 真实手势验证 ScrollPhysics 和 ScrollNotification 接线，不能用 onRefresh 代替。
  await tester.drag(scrollable, const Offset(0, 450));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump();
}

Future<void> _finishAnimations(WidgetTester tester) async {
  // 页面流量动画、请求 spinner 与骨架可能不收敛，使用有界 pump。
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 800));
}

void _expectBusy(WidgetTester tester, {required bool nodes}) {
  final busy = _inside(nodes, find.text('刷新中…'));
  expect(busy, findsOneWidget);
  final button = find.ancestor(
    of: busy,
    matching: find.byWidgetPredicate((w) => w is TextButton),
  );
  expect(tester.widget<TextButton>(button).onPressed, isNull);
  expect(_cooldown(nodes), findsNothing, reason: '请求完成后才启动 60 秒 CD');
}

void main() {
  for (final width in [390.0, 1280.0]) {
    testWidgets('我的 $width：下拉刷新与按钮共用在途防重及完成后的 60 秒 CD', (tester) async {
      final response = Completer<XbResult<XbDomainSubscription>>();
      final f = _Fixture()..accountResponse = response;
      await _pump(tester, page: _Page.mine, width: width, fixture: f);
      expect(f.accountCalls, 0, reason: '渲染我的页面不会自动触发刷新按钮流程');
      expect(f.profileLoads, 1);

      await _pull(tester, nodes: false);
      expect(f.accountCalls, 1);
      _expectBusy(tester, nodes: false);
      await tester.tap(_inside(false, find.text('刷新中…')));
      await tester.pump(const Duration(seconds: 5));
      expect(f.accountCalls, 1);
      expect(f.profileLoads, 1);
      _expectBusy(tester, nodes: false);

      response.complete(XbResult.success(f.data));
      await _finishAnimations(tester);
      expect(f.profileLoads, 2, reason: '沿用按钮刷新完成后重载共享账号信息');
      expect(_cooldown(false), findsOneWidget);
      await tester.tap(_cooldown(false));
      await _pull(tester, nodes: false);
      expect(f.accountCalls, 1, reason: '按钮和下拉共享同一个 60 秒 CD');
      expect(f.profileLoads, 2);
      expect(tester.takeException(), isNull);
    });

    for (final nodes in [_Nodes.populated, _Nodes.empty]) {
      testWidgets('节点 $width/${nodes.name}：短内容可下拉，按钮与下拉共用在途和 CD', (
        tester,
      ) async {
        final response = Completer<XbSyncOutcome>();
        final f = _Fixture(nodeContent: nodes)..syncResponse = response;
        await _pump(tester, page: _Page.nodes, width: width, fixture: f);
        expect(f.syncCalls, 0, reason: '渲染节点页面不会自动手动强刷订阅');
        await _pull(tester, nodes: true);
        expect(f.syncCalls, 1);
        _expectBusy(tester, nodes: true);
        await tester.tap(_inside(true, find.text('刷新中…')));
        await tester.pump(const Duration(seconds: 5));
        expect(f.syncCalls, 1);
        _expectBusy(tester, nodes: true);

        response.complete(XbSyncOutcome.ok);
        await _finishAnimations(tester);
        expect(_cooldown(true), findsOneWidget);
        await tester.tap(_cooldown(true));
        await _pull(tester, nodes: true);
        expect(f.syncCalls, 1);
        expect(f.accountCalls, 0, reason: '节点刷新仍只同步订阅，不调用我的信息刷新');
        expect(f.profileLoads, 1);
        verify(() => f.sync.sync(force: true)).called(1);
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final nodes in [_Nodes.expired, _Nodes.exhausted]) {
    testWidgets('节点 ${nodes.name} 空态：仍能通过下拉进入既有 force 订阅同步', (tester) async {
      final f = await _pump(tester, page: _Page.nodes, nodes: nodes);
      expect(find.text('可用测试节点', findRichText: true), findsNothing);
      await _pull(tester, nodes: true);
      await _finishAnimations(tester);
      expect(f.syncCalls, 1);
      expect(_cooldown(true), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('我的：按钮返回网络失败后，下拉仍遵循原有 60 秒 CD', (tester) async {
    final f = _Fixture();
    when(f.service.getSubscription).thenAnswer((_) async {
      f.accountCalls++;
      return const XbFailure<XbDomainSubscription>(
        XbNetwork(XbNetworkKind.connectionFailed, '测试网络不可用'),
      );
    });
    await _pump(tester, page: _Page.mine, fixture: f);
    await tester.tap(find.text('刷新信息'));
    await _finishAnimations(tester);
    expect(f.accountCalls, 1);
    expect(f.profileLoads, 2);
    expect(_cooldown(false), findsOneWidget);
    await _pull(tester, nodes: false);
    expect(f.accountCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('节点：按钮同步失败后保留旧节点，下拉也受同一 CD 限制', (tester) async {
    final f = _Fixture();
    when(() => f.sync.sync(force: true)).thenAnswer((_) async {
      f.syncCalls++;
      return XbSyncOutcome.failed;
    });
    await _pump(tester, page: _Page.nodes, fixture: f);
    await tester.tap(find.text('刷新节点'));
    await _finishAnimations(tester);
    expect(f.syncCalls, 1);
    expect(find.text('可用测试节点', findRichText: true), findsOneWidget);
    expect(find.text('刷新失败，请稍后重试'), findsOneWidget);
    expect(_cooldown(true), findsOneWidget);
    await _pull(tester, nodes: true);
    expect(f.syncCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('我的与节点各自维护 CD：我的下拉进入冷却不会阻止节点下拉', (tester) async {
    final f = await _pump(tester, page: _Page.both, width: 1280);
    await _pull(tester, nodes: false);
    await _finishAnimations(tester);
    expect(_cooldown(false), findsOneWidget);
    expect(find.text('刷新节点'), findsOneWidget);
    await _pull(tester, nodes: true);
    await _finishAnimations(tester);
    expect(f.accountCalls, 1);
    expect(f.syncCalls, 1);
    expect(_cooldown(false), findsOneWidget);
    expect(_cooldown(true), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('横向分组滚动和切 Tab 不刷新；切到我的后垂直下拉仍能刷新', (tester) async {
    final f = await _pump(tester, page: _Page.pageView);
    final groups = _inside(
      true,
      find.byWidgetPredicate(
        (w) => w is ListView && w.scrollDirection == Axis.horizontal,
      ),
    );
    expect(groups, findsOneWidget);
    await tester.drag(groups, const Offset(200, 0));
    await _finishAnimations(tester);
    expect(f.syncCalls, 0);
    expect(f.accountCalls, 0);

    await tester.drag(find.byType(PageView), const Offset(-450, 0));
    await _finishAnimations(tester);
    expect(find.text('刷新信息'), findsOneWidget);
    expect(f.syncCalls, 0);
    expect(f.accountCalls, 0, reason: '不恢复已经取消的切 Tab 自动刷新');
    await _pull(tester, nodes: false);
    await _finishAnimations(tester);
    expect(f.accountCalls, 1);
    expect(f.syncCalls, 0);
    expect(tester.takeException(), isNull);
  });

  for (final width in [1280.0, 2560.0]) {
    testWidgets('游客两页 $width：拖动页面不发受保护请求，登录后也不自动按钮刷新', (tester) async {
      final f = await _pump(
        tester,
        page: _Page.both,
        width: width,
        guest: true,
      );
      await tester.drag(_tab(false), const Offset(0, 450));
      await tester.drag(_tab(true), const Offset(0, 450));
      await _finishAnimations(tester);
      expect(f.accountCalls, 0);
      expect(f.syncCalls, 0);
      expect(f.profileLoads, 0);
      f.container.read(authStateProvider.notifier).markAuthenticated();
      await _finishAnimations(tester);
      expect(f.accountCalls, 0);
      expect(f.syncCalls, 0);
      expect(f.profileLoads, 1, reason: '登录后的正常账号首载不等于触发刷新按钮');
      expect(tester.takeException(), isNull);
    });
  }

  for (final nodes in [false, true]) {
    testWidgets('${nodes ? '节点' : '我的'}：旧账号下拉晚到，不给新账号施加 CD', (tester) async {
      final f = _Fixture()
        ..accountResponse = Completer<XbResult<XbDomainSubscription>>()
        ..syncResponse = Completer<XbSyncOutcome>();
      await _pump(tester, page: nodes ? _Page.nodes : _Page.mine, fixture: f);
      await _pull(tester, nodes: nodes);
      final auth = f.container.read(authStateProvider.notifier);
      auth.markUnauthenticated();
      await tester.pump();
      f.account = 'B';
      f.container.invalidate(userProfileProvider);
      auth.markAuthenticated();
      await _finishAnimations(tester);
      final bLoads = f.profileLoads;
      if (nodes) {
        f.syncResponse!.complete(XbSyncOutcome.subscriptionExpired);
        f.syncResponse = null;
      } else {
        f.accountResponse!.complete(
          const XbFailure<XbDomainSubscription>(XbUnauthorized('旧账号已过期')),
        );
        f.accountResponse = null;
      }
      await _finishAnimations(tester);
      expect(_cooldown(nodes), findsNothing);
      expect(f.profileLoads, bLoads);
      expect(find.text('套餐已过期，请前往续费 / 购买'), findsNothing);
      await _pull(tester, nodes: nodes);
      await _finishAnimations(tester);
      expect(nodes ? f.syncCalls : f.accountCalls, 2);
      expect(_cooldown(nodes), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
