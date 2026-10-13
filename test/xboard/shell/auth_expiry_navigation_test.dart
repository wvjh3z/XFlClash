/// 认证过期恢复导航：移动根栈与桌面内容栈都返回「我的」游客入口。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart'
    show PatchClashConfig, ProxiesTabState;
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:fl_clash/providers/providers.dart'
    show currentProfileProvider, groupsProvider, selectedMapProvider;
import 'package:fl_clash/xboard/config/xboard_config.dart';
import 'package:fl_clash/xboard/models/order_summary.dart';
import 'package:fl_clash/xboard/models/xb_domain_error.dart';
import 'package:fl_clash/xboard/models/xb_domain_subscription.dart';
import 'package:fl_clash/xboard/models/xb_domain_types.dart';
import 'package:fl_clash/xboard/models/xb_invite.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/pages/order_list_page.dart';
import 'package:fl_clash/xboard/providers/auth_expiry_notice_provider.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/providers/invite_provider.dart';
import 'package:fl_clash/xboard/providers/user_profile_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/sdk/xboard_service.dart';
import 'package:fl_clash/xboard/shell/sheets/login_sheet.dart';
import 'package:fl_clash/xboard/shell/widgets/xb_bottom_bar.dart';
import 'package:fl_clash/xboard/shell/widgets/xb_nav_rail.dart';
import 'package:fl_clash/xboard/shell/xboard_app_shell.dart';

import '_net_detection_stub.dart';

const _expiredMessage = '登录已过期，请重新登录';

class _MockService extends Mock implements XboardService {}

class _Authenticated extends AuthStateNotifier {
  @override
  AuthState build() => AuthState.authenticated;
}

class _Fixture {
  _Fixture(this.container, this.orders);

  final ProviderContainer container;
  final Completer<XbResult<XbPagedList<OrderSummary>>> orders;

  void expire() {
    container.read(authStateProvider.notifier).markUnauthenticated();
    container.read(authExpiryNoticeProvider.notifier).notifyExpired();
  }
}

Future<_Fixture> _pumpShell(WidgetTester tester, {required bool mobile}) async {
  tester.view.physicalSize = mobile
      ? const Size(360, 800)
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

  final service = _MockService();
  final orders = Completer<XbResult<XbPagedList<OrderSummary>>>();
  when(
    () => service.getOrders(forceRefresh: true),
  ).thenAnswer((_) => orders.future);
  final container = ProviderContainer(
    overrides: [
      xboardServiceProvider.overrideWithValue(service),
      isMobileViewProvider.overrideWith((ref) => mobile),
      authStateProvider.overrideWith(_Authenticated.new),
      isStartProvider.overrideWith((ref) => false),
      proxiesTabStateProvider.overrideWith(
        (ref) => const ProxiesTabState(
          groups: [],
          currentGroupName: null,
          proxyCardType: ProxyCardType.expand,
          columns: 2,
        ),
      ),
      netDetectionOverride(),
      userProfileProvider.overrideWith(
        (ref) async => const XbDomainSubscription(
          email: 'account-a@example.invalid',
          uuid: 'account-a',
          planName: '测试套餐',
          totalBytes: 100 * 1024 * 1024 * 1024,
          usedBytes: 10 * 1024 * 1024 * 1024,
          expiredAt: null,
          planId: 1,
        ),
      ),
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
      groupsProvider.overrideWithValue(const []),
      selectedMapProvider.overrideWith((ref) => const {}),
      currentProfileProvider.overrideWith((ref) => null),
      patchClashConfigProvider.overrideWithBuild(
        (ref, _) => const PatchClashConfig(mode: Mode.rule),
      ),
    ],
  );
  addTearDown(container.dispose);
  container.read(bootstrapReadyProvider.notifier).set(true);
  container.read(coreStatusProvider.notifier).value = CoreStatus.disconnected;
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: XboardAppShell()),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 800));
  return _Fixture(container, orders);
}

Future<void> _openOrders(WidgetTester tester, {required bool mobile}) async {
  final navigation = mobile ? find.byType(XbBottomBar) : find.byType(XbNavRail);
  await tester.tap(find.descendant(of: navigation, matching: find.text('我的')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 800));
  final entry = find.text('我的订单');
  await tester.ensureVisible(entry);
  // xbPush 使用进程内 DateTime.now() 的 500ms 连点窗口。pump 只推进 Widget 测试的
  // 虚拟时间，上一条测试的 push 仍可能落在这个真实时间窗口内；跨测试等待窗口结束，
  // 再走真实入口，保留 OrderListPage 必须成功打开的断言。
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 550)),
  );
  await tester.tap(entry);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  expect(find.byType(OrderListPage), findsOneWidget);
}

Future<void> _settleExpiry(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 800));
}

void _expectGuestMine(WidgetTester tester, {required bool mobile}) {
  expect(find.byType(OrderListPage), findsNothing);
  expect(find.text('未登录'), findsOneWidget);
  expect(find.text('登录 / 注册'), findsOneWidget);
  expect(find.text('退出登录'), findsNothing);
  expect(find.byType(LoginSheet), findsNothing);
  if (mobile) {
    expect(
      tester.widget<XbBottomBar>(find.byType(XbBottomBar)).currentIndex,
      2,
    );
  } else {
    expect(tester.widget<XbNavRail>(find.byType(XbNavRail)).currentIndex, 2);
  }
}

void main() {
  for (final mobile in [true, false]) {
    final layout = mobile ? '移动端' : '桌面端';

    testWidgets('$layout：订单认证过期返回我的游客卡，只提示一次并保留手动登录入口', (tester) async {
      final original = ErrorWidget.builder;
      try {
        final fixture = await _pumpShell(tester, mobile: mobile);
        await _openOrders(tester, mobile: mobile);
        fixture.expire();
        fixture.orders.complete(
          const XbFailure(XbUnauthorized(_expiredMessage)),
        );
        await _settleExpiry(tester);
        _expectGuestMine(tester, mobile: mobile);
        expect(find.text(_expiredMessage), findsOneWidget);

        // 普通 rebuild 不应重放过期通知，提示消失后也不重新出现。
        for (var i = 0; i < 3; i++) {
          tester.element(find.byType(XboardAppShell)).markNeedsBuild();
          await tester.pump();
          expect(find.text(_expiredMessage), findsOneWidget);
        }
        await tester.pump(const Duration(seconds: 4));
        await tester.pump(const Duration(milliseconds: 300));
        tester.element(find.byType(XboardAppShell)).markNeedsBuild();
        await tester.pump();
        expect(find.text(_expiredMessage), findsNothing);

        // 仅在用户主动点击游客卡时打开登录，不由认证失效强弹。
        await tester.tap(find.text('登录 / 注册'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(LoginSheet), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        ErrorWidget.builder = original;
        await tester.pumpWidget(const SizedBox.shrink());
      }
    });

    testWidgets('$layout：认证过期同时收起根登录弹窗与订单子页', (tester) async {
      final original = ErrorWidget.builder;
      try {
        final fixture = await _pumpShell(tester, mobile: mobile);
        await _openOrders(tester, mobile: mobile);
        unawaited(showLoginSheet(tester.element(find.byType(OrderListPage))));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(LoginSheet), findsOneWidget);

        fixture.expire();
        await _settleExpiry(tester);
        _expectGuestMine(tester, mobile: mobile);
        expect(find.text(_expiredMessage), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        ErrorWidget.builder = original;
        await tester.pumpWidget(const SizedBox.shrink());
      }
    });

    testWidgets('$layout：网络错误和普通登出不发送认证过期导航或提示', (tester) async {
      final original = ErrorWidget.builder;
      try {
        final fixture = await _pumpShell(tester, mobile: mobile);
        await _openOrders(tester, mobile: mobile);
        fixture.orders.complete(
          const XbFailure(XbNetwork(XbNetworkKind.connectionFailed, '网络未连接')),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(OrderListPage), findsOneWidget);
        expect(
          fixture.container.read(authStateProvider),
          AuthState.authenticated,
        );
        expect(find.text(_expiredMessage), findsNothing);

        fixture.container
            .read(authStateProvider.notifier)
            .markUnauthenticated();
        await _settleExpiry(tester);
        expect(find.byType(OrderListPage), findsOneWidget);
        expect(find.text(_expiredMessage), findsNothing);
        expect(find.byType(LoginSheet), findsNothing);
        expect(fixture.container.read(authExpiryNoticeProvider), 0);
        expect(tester.takeException(), isNull);
      } finally {
        ErrorWidget.builder = original;
        await tester.pumpWidget(const SizedBox.shrink());
      }
    });

    testWidgets('$layout：帧后处理前 B 已登录，旧过期通知不关闭 B 的页面', (tester) async {
      final original = ErrorWidget.builder;
      try {
        final fixture = await _pumpShell(tester, mobile: mobile);
        await _openOrders(tester, mobile: mobile);
        fixture.expire();
        fixture.container.read(authStateProvider.notifier).markAuthenticated();
        await _settleExpiry(tester);
        expect(
          fixture.container.read(authStateProvider),
          AuthState.authenticated,
        );
        expect(find.byType(OrderListPage), findsOneWidget);
        expect(find.text(_expiredMessage), findsNothing);
        expect(find.byType(LoginSheet), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        ErrorWidget.builder = original;
        await tester.pumpWidget(const SizedBox.shrink());
      }
    });
  }
}
