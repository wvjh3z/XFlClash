/// 形态 A 页面 golden 核对（套餐列表 / 订单列表 / 流量重置 / 我的已登录）。
///
/// 用注入数据渲染页面 → golden 截图，跟原型对比（人工/像素）。不依赖模拟器，可重复、进 CI。
/// 与 a11y_golden_test（plan detail / payment）互补，覆盖剩余购买链路屏。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:fl_clash/xboard/models/order_summary.dart';
import 'package:fl_clash/xboard/models/plan_item.dart';
import 'package:fl_clash/xboard/models/xb_domain_subscription.dart';
import 'package:fl_clash/xboard/models/xb_domain_types.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/pages/order_list_page.dart';
import 'package:fl_clash/xboard/pages/plan_list_page.dart';
import 'package:fl_clash/xboard/pages/reset_traffic_page.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/providers/user_profile_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/sdk/xboard_service.dart';
import 'package:fl_clash/xboard/shell/tabs/mine/mine_tab.dart';
import 'package:fl_clash/xboard/widgets/xb_ui_kit.dart' show XbBrandTheme;

class _MockService extends Mock implements XboardService {}

const _cjkFontPaths = [
  '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
  '/System/Library/Fonts/PingFang.ttc',
];

Future<void> _loadCjkFont() async {
  for (final path in _cjkFontPaths) {
    final f = File(path);
    if (!f.existsSync()) continue;
    try {
      final bytes = await f.readAsBytes();
      final loader = FontLoader('Roboto')
        ..addFont(Future.value(ByteData.view(bytes.buffer)));
      await loader.load();
      return;
    } catch (_) {}
  }
}

final _fixedCreated = DateTime(2026, 6, 5, 12, 30);

// 真实账号那份数据（98% 用量，触发流量重置告警卡）。
// 到期/重置时间用「相对当前日期的固定偏移」→ 「剩 N 天」恒定，golden 不随运行日期飘移
// （xbResetText / _expireText 内部用 DateTime.now() 算剩余天数，固定日期会导致每天像素漂移）。
XbDomainSubscription get _sub {
  final today = DateTime.now();
  final base = DateTime(today.year, today.month, today.day);
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
  setUpAll(_loadCjkFont);

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
    await expectLater(find.byType(PlanListPage),
        matchesGoldenFile('goldens/page_plan_list.png'));
  });

  testWidgets('订单列表页 golden（状态色：完成=绿/取消=红/待付=琥珀）', (t) async {
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
        overrides: [xboardServiceProvider.overrideWithValue(svc)],
        child: app(const OrderListPage()),
      ),
    );
    expect(t.takeException(), isNull);
    await expectLater(find.byType(OrderListPage),
        matchesGoldenFile('goldens/page_order_list.png'));
  });

  testWidgets('我的（已登录 98% → 触发流量重置卡）golden', (t) async {
    await pump(
      t,
      ProviderScope(
        overrides: [
          authStateProvider.overrideWith(_FakeAuth.new),
          userProfileProvider.overrideWith((ref) async => _sub),
        ],
        child: app(const XbBrandTheme(
          brandColor: Color(0xFFD92E1A),
          // active:false → 账号卡填充动画直接置终态（不播放），golden 像素确定、不因动画末帧抖动。
          child: MineTab(active: false),
        )),
      ),
    );
    expect(t.takeException(), isNull);
    await expectLater(find.byType(MineTab),
        matchesGoldenFile('goldens/page_mine_auth.png'));
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
    await expectLater(find.byType(MineTab),
        matchesGoldenFile('goldens/page_mine_error.png'));
  });

  testWidgets('流量重置包页 golden', (t) async {
    final svc = _MockService();
    when(svc.getPlans).thenAnswer((_) async => XbResult.success([_resetPlan]));
    await pump(
      t,
      ProviderScope(
        overrides: [xboardServiceProvider.overrideWithValue(svc)],
        child: app(const ResetTrafficPage(planId: 1, planName: '标准套餐')),
      ),
    );
    expect(t.takeException(), isNull);
    await expectLater(find.byType(ResetTrafficPage),
        matchesGoldenFile('goldens/page_reset_traffic.png'));
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
    await expectLater(find.byType(MineTab),
        matchesGoldenFile('goldens/page_mine_guest.png'));
  });
}
