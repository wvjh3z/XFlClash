/// 待支付订单横幅区块单测：有 pending 订单显示横幅 + 两按钮；无则收起。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:fl_clash/xboard/models/order_summary.dart';
import 'package:fl_clash/xboard/models/xb_domain_error.dart';
import 'package:fl_clash/xboard/models/xb_domain_types.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/pages/pending_order_section.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/sdk/xboard_service.dart';

class _MockService extends Mock implements XboardService {}

OrderSummary _order(XbOrderStatus status) => OrderSummary(
      tradeNo: 'T-1',
      planName: '标准套餐',
      period: XbPlanPeriod.quarterly,
      totalAmountYuan: 40.00,
      status: status,
      createdAt: DateTime(2026, 6, 5),
    );

Future<void> pump(WidgetTester tester, XboardService svc) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [xboardServiceProvider.overrideWithValue(svc)],
      child: const MaterialApp(
        home: Scaffold(body: PendingOrderSection()),
      ),
    ),
  );
  await tester.pump(); // resolve future
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  testWidgets('有 pending 订单 → 显示横幅 + 取消/立即支付', (tester) async {
    final svc = _MockService();
    when(() => svc.getOrders(
        page: any(named: 'page'),
        pageSize: any(named: 'pageSize'),
        forceRefresh: any(named: 'forceRefresh'))).thenAnswer((_) async => XbResult.success(
          XbPagedList(items: [_order(XbOrderStatus.pending)], page: 1, pageSize: 20, total: 1),
        ));
    await pump(tester, svc);
    expect(find.text('有待支付订单'), findsOneWidget);
    expect(find.text('标准套餐 · 季付'), findsOneWidget);
    expect(find.text('¥40.00'), findsOneWidget);
    expect(find.text('取消订单'), findsOneWidget);
    expect(find.text('立即支付'), findsOneWidget);
  });

  testWidgets('无 pending 订单 → 横幅收起', (tester) async {
    final svc = _MockService();
    when(() => svc.getOrders(
        page: any(named: 'page'),
        pageSize: any(named: 'pageSize'),
        forceRefresh: any(named: 'forceRefresh'))).thenAnswer((_) async => XbResult.success(
          XbPagedList(items: [_order(XbOrderStatus.completed)], page: 1, pageSize: 20, total: 1),
        ));
    await pump(tester, svc);
    expect(find.text('有待支付订单'), findsNothing);
  });

  testWidgets('订单查询失败 → 横幅不显示（永不打断）', (tester) async {
    final svc = _MockService();
    when(() => svc.getOrders(
        page: any(named: 'page'),
        pageSize: any(named: 'pageSize'),
        forceRefresh: any(named: 'forceRefresh')))
        .thenAnswer((_) async => XbResult.failure(const XbServer(500, 'x')));
    await pump(tester, svc);
    expect(find.text('有待支付订单'), findsNothing);
  });
}
