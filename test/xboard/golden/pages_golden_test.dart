/// 形态 A 页面 golden 核对（套餐列表 / 订单列表 / 流量重置 / 我的已登录）。
///
/// 用注入数据渲染页面 → golden 截图，跟原型对比（人工/像素）。不依赖模拟器，可重复、进 CI。
/// 与 a11y_golden_test（plan detail / payment）互补，覆盖剩余购买链路屏。
library;

import 'golden_environment.dart';
import 'shell_fixture.dart';
import 'home_states_golden_test.dart' show pumpHome;
import 'package:fl_clash/enum/enum.dart' show CoreStatus;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:fl_clash/xboard/config/xboard_config.dart';
import 'package:fl_clash/xboard/models/order_summary.dart';
import 'package:fl_clash/xboard/models/plan_item.dart';
import 'package:fl_clash/xboard/models/xb_domain_subscription.dart';
import 'package:fl_clash/xboard/models/xb_domain_types.dart';
import 'package:fl_clash/xboard/models/xb_invite.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/pages/order_list_page.dart';
import 'package:fl_clash/xboard/pages/plan_list_page.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/providers/user_profile_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/sdk/xboard_service.dart';
import 'package:fl_clash/xboard/shell/tabs/mine/mine_tab.dart';
import 'package:fl_clash/xboard/widgets/xb_ui_kit.dart' show XbBrandTheme;

class _MockService extends Mock implements XboardService {}

final _fixedCreated = DateTime(2026, 6, 5, 12, 30);

// 确定性账号夹具：98%用量；告警入口已移到首页，不应在“我的”重现旧卡片。
// 到期/重置时间用「相对当前日期的固定偏移」→ 「剩 N 天」恒定，golden 不随运行日期飘移
// （xbResetText / _expireText 内部用 DateTime.now() 算剩余天数，固定日期会导致每天像素漂移）。
/// golden 固定基准时刻（绝对,不随真实日期漂移）。账号卡到期/重置「剩余N天」按它计算。
final _goldenNow = DateTime(2026, 1, 1, 12, 0);

XbDomainSubscription get _sub {
  // 固定绝对基准（不再用 DateTime.now()）：保证「到期绝对日期」与「剩余N天」双双稳定，
  // 配合下方 MineTab(now: _goldenNow) 渲染，golden 任何一天跑都一致。
  final base = DateTime(2026, 1, 1);
  return XbDomainSubscription(
      email: '123456@qq.com',
      uuid: 'uid-real',
      planName: '标准套餐',
      totalBytes: 250 * 1024 * 1024 * 1024,
      usedBytes: (245.7 * 1024 * 1024 * 1024).round(),
      expiredAt: base.add(const Duration(days: 27, hours: 8, minutes: 30)),
      nextResetAt: base.add(const Duration(days: 10, hours: 11, minutes: 17)),
      resetDay: 26,
      planId: 1,
    );
}

const _plans = [
  PlanItem(
    id: 1,
    name: '轻量套餐',
    description: '<p>100 GB/月 · 全部线路 · 3 设备</p>',
    transferEnableGb: 100,
    prices: [PricePlan(period: XbPlanPeriod.monthly, amountYuan: 10.00)],
  ),
  PlanItem(
    id: 2,
    name: '标准套餐',
    description: '<p>250 GB/月 · 全部线路 · 5 设备</p>',
    transferEnableGb: 250,
    prices: [PricePlan(period: XbPlanPeriod.monthly, amountYuan: 15.00)],
  ),
  PlanItem(
    id: 3,
    name: '畅享套餐',
    description: '<p>1 TB/月 · 全部线路 · 10 设备</p>',
    transferEnableGb: 1024,
    prices: [PricePlan(period: XbPlanPeriod.monthly, amountYuan: 28.00)],
  ),
];

List<OrderSummary> get _orders => [
      OrderSummary(
        tradeNo: '2026060512001',
        planName: '标准套餐',
        period: XbPlanPeriod.quarterly,
        totalAmountYuan: 40.00,
        status: XbOrderStatus.completed,
        createdAt: _fixedCreated,
      ),
      OrderSummary(
        tradeNo: '2026052800002',
        planName: '流量重置包',
        period: XbPlanPeriod.resetTraffic,
        totalAmountYuan: 8.00,
        status: XbOrderStatus.completed,
        createdAt: DateTime(2026, 5, 28),
      ),
      OrderSummary(
        tradeNo: '2026050500003',
        planName: '标准套餐',
        period: XbPlanPeriod.monthly,
        totalAmountYuan: 15.00,
        status: XbOrderStatus.cancelled,
        createdAt: DateTime(2026, 5, 5),
      ),
      OrderSummary(
        tradeNo: '2026043000004',
        planName: '畅享套餐',
        period: XbPlanPeriod.yearly,
        totalAmountYuan: 298.00,
        status: XbOrderStatus.pending,
        createdAt: DateTime(2026, 4, 30),
      ),
    ];

const _resetPlan = PlanItem(
  id: 1,
  name: '标准套餐',
  description: '<p>250 GB/月</p>',
  transferEnableGb: 250,
  prices: [
    PricePlan(period: XbPlanPeriod.monthly, amountYuan: 15.00),
    PricePlan(period: XbPlanPeriod.resetTraffic, amountYuan: 8.00),
  ],
);

class _FakeAuth extends AuthStateNotifier {
  @override
  AuthState build() => AuthState.authenticated;
}

class _GuestAuth extends AuthStateNotifier {
  @override
  AuthState build() => AuthState.unauthenticated;
}

void main() {
  setUpAll(loadGoldenFonts);

  Future<void> pump(WidgetTester tester, Widget scope) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(scope);
    await tester.pumpAndSettle();
  }

  Widget app(Widget page) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(useMaterial3: true, brightness: Brightness.light),
        home: Scaffold(body: page),
      );

  testWidgets('套餐列表页 golden', (t) async {
    final svc = _MockService();
    when(svc.getPlans).thenAnswer((_) async => XbResult.success(_plans));
    await pump(
      t,
      ProviderScope(
        overrides: [xboardServiceProvider.overrideWithValue(svc)],
        child: app(const PlanListPage()),
      ),
    );
    expect(t.takeException(), isNull);
    await expectXbGolden(t, find.byType(PlanListPage), 'goldens/page_plan_list.png');
  });

  testWidgets('订单列表页 golden（独立待付按钮和历史分组）', (t) async {
    final svc = _MockService();
    when(() => svc.getOrders(
              page: any(named: 'page'),
              pageSize: any(named: 'pageSize'),
              forceRefresh: any(named: 'forceRefresh'),
            ))
        .thenAnswer((_) async => XbResult.success(XbPagedList(
              items: _orders,
              page: 1,
              pageSize: 20,
              total: _orders.length,
            )));
    await pump(
      t,
      ProviderScope(
        overrides: [authStateProvider.overrideWith(_FakeAuth.new), xboardServiceProvider.overrideWithValue(svc)],
        child: app(const OrderListPage()),
      ),
    );
    expect(t.takeException(), isNull);
    expect(find.widgetWithText(FilledButton, '继续支付'), findsOneWidget);
    expect(find.text('历史订单'), findsOneWidget);
    await expectXbGolden(t, find.byType(OrderListPage), 'goldens/page_order_list.png');
  });

  testWidgets('我的（已登录、返佣与客服均已配置）golden', (t) async {
    final service = _MockService();
    when(service.getInviteInfo).thenAnswer(
      (_) async => const XbSuccess(
        XbInviteInfo(
          code: 'FIXTURE',
          registeredCount: 3,
          pendingYuan: 12,
          totalYuan: 48,
          commissionRate: 17,
          commissionBalanceYuan: 36,
          accountBalanceYuan: 0,
        ),
      ),
    );
    await pumpShell(t, core: CoreStatus.connected, mobile: true, size: const Size(390,844),
      config: const XboardConfig(subscribeUserAgent: 'golden', devApiEndpoint: 'https://example.invalid',
        devSubscriptionEndpoint: 'https://example.invalid', debug: false,kIsTest:true,formA:true,crispWebsiteId:'fixture-website-id'),
      subscription: _sub.copyWith(usedBytes: _sub.totalBytes * 62 ~/ 100, expiredAt:null,nextResetAt:null,resetDay:null), service: service);
    await t.tap(find.text('我的').hitTestable());
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    expect(find.text('购买重置包立即恢复本月流量', findRichText: true), findsNothing);
    expect(find.text('续费当前套餐', findRichText: true), findsNothing);
    expect(find.text('我的订单', findRichText: true), findsOneWidget);
    expect(find.text('已用 62.0%'), findsOneWidget);
    expect(find.text('返 17%'), findsOneWidget);
    expect(find.text('在线客服'), findsOneWidget);
    await expectXbGolden(t, find.byKey(const ValueKey('home-golden-window')), 'goldens/page_mine_auth.png');
  });

  testWidgets('我的（账号信息加载失败）golden', (t) async {
    await pump(
      t,
      ProviderScope(
        overrides: [
          authStateProvider.overrideWith(_FakeAuth.new),
          // 抛错 → AsyncError → _AccountErrorCard。
          userProfileProvider.overrideWith(
              (ref) async => throw Exception('network down')),
        ],
        child: app(const XbBrandTheme(
          brandColor: Color(0xFFD92E1A),
          child: MineTab(),
        )),
      ),
    );
    expect(t.takeException(), isNull);
    await expectXbGolden(t, find.byType(MineTab), 'goldens/page_mine_error.png');
  });

  testWidgets('首页点击重置流量只打开购买须知，取消返回首页', (t) async {
    final svc = _MockService();
    when(svc.getPlans).thenAnswer((_) async => XbSuccess([_resetPlan]));
    await pumpHome(t, auth: AuthState.authenticated, core: CoreStatus.connected,
      isStart: true, service: svc,
      sub: _sub.copyWith(usedBytes: _sub.totalBytes * 9 ~/ 10, expiredAt: null, nextResetAt: null, resetDay: 6));
    await t.tap(find.text('重置流量'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('流量重置包购买须知'), findsOneWidget);
    expect(find.text('确认购买'), findsOneWidget);
    expect(find.text('购买流量重置包'), findsNothing);
    await expectXbGolden(t, find.byKey(const ValueKey('home-golden-window')), 'goldens/page_reset_traffic.png');
    await t.tap(find.text('再想想'));
    await t.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('重置流量'), findsOneWidget);
    verify(svc.getPlans).called(1);
    verifyNever(() => svc.createOrder(1, XbPlanPeriod.resetTraffic));
  });

  testWidgets('我的（游客态）golden', (t) async {
    await pump(
      t,
      ProviderScope(
        overrides: [
          authStateProvider.overrideWith(_GuestAuth.new),
        ],
        child: app(const XbBrandTheme(
          brandColor: Color(0xFFD92E1A),
          child: MineTab(),
        )),
      ),
    );
    expect(t.takeException(), isNull);
    await expectXbGolden(t, find.byType(MineTab), 'goldens/page_mine_guest.png');
  });
}
