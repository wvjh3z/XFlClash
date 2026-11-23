/// 待支付订单横幅区块单测：有 pending 订单显示横幅 + 两按钮；无则收起。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:fl_clash/xboard/models/order_summary.dart';
import 'package:fl_clash/xboard/models/xb_domain_error.dart';
import 'package:fl_clash/xboard/models/xb_domain_types.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/pages/pending_order_section.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/providers/network_recovery_provider.dart';
import 'package:fl_clash/xboard/sdk/xboard_service.dart';

class _MockService extends Mock implements XboardService {}
class _SignedIn extends AuthStateNotifier {
  @override
  AuthState build() => AuthState.authenticated;
}

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
      overrides: [xboardServiceProvider.overrideWithValue(svc), authStateProvider.overrideWith(_SignedIn.new)],
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

  for (final validZero in [false, true]) {
    testWidgets('pending banner skips incomplete orders; valid zero=$validZero', (tester) async {
      final svc = _MockService();
      final base = _order(XbOrderStatus.pending);
      final orders = [base.copyWith(status: null), base.copyWith(totalAmountYuan: null),
        if (validZero) base.copyWith(tradeNo: 'Z', totalAmountYuan: 0)];
      when(() => svc.getOrders(forceRefresh:true)).thenAnswer((_) async => XbSuccess(
        XbPagedList(items: orders, page: 1, pageSize: 20, total: orders.length)));
      await pump(tester, svc);
      expect(find.text('立即支付'), validZero ? findsOneWidget : findsNothing);
      expect(find.text('取消订单'), validZero ? findsOneWidget : findsNothing);
      expect(find.text('¥0.00'), validZero ? findsOneWidget : findsNothing);
    });
  }

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

  testWidgets('未知待付没有取消权限，恢复只读后才确认为空', (tester) async {
    final svc = _MockService();
    when(() => svc.getOrders(
        page: any(named: 'page'),
        pageSize: any(named: 'pageSize'),
        forceRefresh: any(named: 'forceRefresh')))
        .thenAnswer((_) async => XbResult.failure(const XbServer(500, 'x')));
    await pump(tester, svc);
    expect(find.text('有待支付订单'), findsNothing);
    expect(find.text('待支付订单状态待核实'), findsOneWidget);
    expect(find.text('取消订单'), findsNothing);
    when(() => svc.getOrders(forceRefresh: true)).thenAnswer((_) async => const XbSuccess(
      XbPagedList<OrderSummary>(items: [], page: 1, pageSize: 20, total: 0)));
    final container = ProviderScope.containerOf(tester.element(find.byType(PendingOrderSection)));
    container.read(networkRecoveryProvider.notifier).publish();
    await tester.pumpAndSettle();
    expect(find.text('待支付订单状态待核实'), findsNothing);
    expect(find.text('有待支付订单'), findsNothing);
    verifyNever(() => svc.cancelOrder(any()));
  });
}
