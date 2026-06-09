/// 订单列表页实时性回归：进入时必须 forceRefresh=true 拉取（绕 SDK 缓存），
/// 否则新建的待支付订单看不到、转圈一闪而过。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:fl_clash/xboard/models/order_summary.dart';
import 'package:fl_clash/xboard/models/xb_domain_types.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/sdk/xboard_service.dart';
import 'package:fl_clash/xboard/pages/order_list_page.dart';

class _MockService extends Mock implements XboardService {}

void main() {
  testWidgets('OrderListPage 进入时以 forceRefresh:true 拉订单（实时）', (tester) async {
    final svc = _MockService();
    final pending = OrderSummary(
      tradeNo: 'T-PENDING-1',
      planName: '专业版',
      period: XbPlanPeriod.monthly,
      totalAmountYuan: 12.0,
      status: XbOrderStatus.pending,
      createdAt: DateTime(2026, 6, 9, 11, 0),
    );
    when(() => svc.getOrders(
          page: any(named: 'page'),
          pageSize: any(named: 'pageSize'),
          forceRefresh: any(named: 'forceRefresh'),
        )).thenAnswer((_) async => XbResult.success(
          XbPagedList<OrderSummary>(
              items: [pending], page: 1, pageSize: 20, total: 1),
        ));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [xboardServiceProvider.overrideWithValue(svc)],
        child: const MaterialApp(home: OrderListPage()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // 关键断言：必须以 forceRefresh:true 调用（绕缓存实时拉）。
    final captured = verify(() => svc.getOrders(
          page: any(named: 'page'),
          pageSize: any(named: 'pageSize'),
          forceRefresh: captureAny(named: 'forceRefresh'),
        )).captured;
    expect(captured, contains(true),
        reason: '订单列表必须强制实时拉取，否则待支付订单看不到');

    // 待支付订单应显示出来。
    expect(find.text('专业版'), findsOneWidget);
  });
}
