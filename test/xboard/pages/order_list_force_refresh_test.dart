/// 订单列表页实时性回归：进入时必须 forceRefresh=true 拉取（绕 SDK 缓存），
/// 否则新建的待支付订单看不到、转圈一闪而过。
library;

import 'dart:async';

import 'package:flutter/widgets.dart' show DecoratedSliver;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';

import 'package:fl_clash/xboard/models/order_summary.dart';
import 'package:fl_clash/xboard/models/xb_domain_types.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/sdk/xboard_service.dart';
import 'package:fl_clash/xboard/pages/order_list_page.dart';
import 'package:fl_clash/xboard/pages/order_payment_page.dart';
import 'package:fl_clash/xboard/widgets/xb_components.dart' show XbCard;

class _SignedIn extends AuthStateNotifier {
  @override
  AuthState build() => AuthState.authenticated;
}

class _MockService extends Mock implements XboardService {}

OrderSummary _order(String tradeNo, String planName, XbOrderStatus status) =>
    OrderSummary(
      tradeNo: tradeNo,
      planName: planName,
      period: XbPlanPeriod.monthly,
      totalAmountYuan: 12,
      status: status,
      createdAt: DateTime(2026, 6, 9, 11),
    );

Future<void> _pumpOrders(
  WidgetTester tester,
  _MockService service, {
  double width = 390,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 844);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [authStateProvider.overrideWith(_SignedIn.new), xboardServiceProvider.overrideWithValue(service)],
      child: const MaterialApp(home: OrderListPage()),
    ),
  );
  await tester.pumpAndSettle();
}

_MockService _serviceWith(List<OrderSummary> orders) {
  final service = _MockService();
  when(
    () => service.getOrders(page: 1, pageSize: 50, forceRefresh: true),
  ).thenAnswer(
    (_) async => XbSuccess(
      XbPagedList(
        items: orders,
        page: 1,
        pageSize: 50,
        total: orders.length,
      ),
    ),
  );
  return service;
}

void main() {
  testWidgets('sign-out drops A immediately; B reload cannot retain A or its actions', (tester) async {
    final a = _serviceWith([_order('A', 'A的订单', XbOrderStatus.pending)]);
    final b = _MockService();
    final delayed = Completer<XbResult<XbPagedList<OrderSummary>>>();
    when(() => b.getOrders(page: 1, pageSize: 50, forceRefresh: true)).thenAnswer((_) => delayed.future);
    final c = ProviderContainer(overrides: [xboardServiceProvider.overrideWithValue(a)]);
    addTearDown(c.dispose);
    final auth = c.read(authStateProvider.notifier)..markAuthenticated();
    await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const MaterialApp(home: OrderListPage())));
    await tester.pumpAndSettle();
    expect(find.text('A的订单', findRichText: true), findsOneWidget);
    auth.markUnauthenticated();
    await tester.pump();
    expect(find.text('A的订单', findRichText: true), findsNothing);
    expect(find.text('请先登录后查看订单'), findsOneWidget);
    c.updateOverrides([xboardServiceProvider.overrideWithValue(b)]);
    auth.markAuthenticated();
    await tester.pump();
    expect(find.text('继续支付'), findsNothing);
    delayed.complete(XbSuccess(XbPagedList(items: [_order('B', 'B的订单', XbOrderStatus.completed)], page: 1, pageSize: 50, total: 1)));
    await tester.pumpAndSettle();
    expect(find.text('B的订单', findRichText: true), findsOneWidget);
    verify(() => b.getOrders(page: 1, pageSize: 50, forceRefresh: true)).called(1);
  });

  testWidgets('late old-owner response cannot replace the newly loaded list', (tester) async {
    final old = _MockService();
    final lateResult = Completer<XbResult<XbPagedList<OrderSummary>>>();
    when(() => old.getOrders(page: 1, pageSize: 50, forceRefresh: true)).thenAnswer((_) => lateResult.future);
    final next = _serviceWith([_order('B', '新账号订单', XbOrderStatus.completed)]);
    final c = ProviderContainer(overrides: [xboardServiceProvider.overrideWithValue(old)]);
    addTearDown(c.dispose);
    final auth = c.read(authStateProvider.notifier)..markAuthenticated();
    await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const MaterialApp(home: OrderListPage())));
    auth.markUnauthenticated();
    c.updateOverrides([xboardServiceProvider.overrideWithValue(next)]);
    auth.markAuthenticated();
    await tester.pumpAndSettle();
    lateResult.complete(XbSuccess(XbPagedList(items: [_order('A','旧账号迟到订单',XbOrderStatus.pending)],page:1,pageSize:50,total:1)));
    await tester.pumpAndSettle();
    expect(find.text('新账号订单', findRichText: true), findsOneWidget);
    expect(find.text('旧账号迟到订单', findRichText: true), findsNothing);
    expect(find.text('继续支付'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('missing amount is not rendered as a zero-price pending order', (tester) async {
    final unknown = _order('M', '未报价', XbOrderStatus.pending).copyWith(totalAmountYuan: null);
    final zero = _order('Z', '零价套餐', XbOrderStatus.pending).copyWith(totalAmountYuan: 0);
    expect(OrderSummary.fromJson(unknown.toJson()).needsVerification, isTrue);
    expect(OrderSummary.fromJson(zero.toJson()).canContinuePayment, isTrue);
    await _pumpOrders(tester, _serviceWith([unknown, zero]));
    expect(find.text('金额待核实'), findsOneWidget);
    expect(find.text('待核实订单'), findsOneWidget);
    expect(find.text('¥0.00'), findsOneWidget);
    expect(find.text('继续支付'), findsOneWidget);
  });

  testWidgets('unknown status or period is visible without payment or history actions', (tester) async {
    final pending = _order('OLD','周期缺失',XbOrderStatus.pending);
    await _pumpOrders(tester, _serviceWith([pending.copyWith(period: null), pending.copyWith(tradeNo:'OTHER',status:null)]));
    expect(find.text('待核实订单'),findsOneWidget);
    expect(find.text('状态待核实'),findsNWidgets(2));
    expect(find.textContaining('周期未知'),findsOneWidget);
    expect(find.text('历史订单'),findsNothing);
    expect(find.text('继续支付'),findsNothing);
  });

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
        )).thenAnswer((invocation) async {
          final page = invocation.namedArguments[#page] as int;
          final archived = pending.copyWith(
            tradeNo: 'T-DONE',
            planName: '已完成套餐',
            status: XbOrderStatus.completed,
          );
          return XbResult.success(XbPagedList<OrderSummary>(
            items: page == 1 ? [archived] : [pending],
            page: page,
            pageSize: 1,
            total: 2,
          ));
        });

    await _pumpOrders(tester, svc);

    // 关键断言：必须以 forceRefresh:true 调用（绕缓存实时拉）。
    final captured = verify(() => svc.getOrders(
          page: any(named: 'page'),
          pageSize: any(named: 'pageSize'),
          forceRefresh: captureAny(named: 'forceRefresh'),
        )).captured;
    expect(captured, [true, false],
        reason: '首页刷新同一份快照，后续分页不能重置快照');

    // 待支付订单应显示出来。
    expect(find.text('专业版', findRichText: true), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '继续支付'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('需要处理')).dy,
      lessThan(tester.getTopLeft(find.text('历史订单')).dy),
    );
  });

  testWidgets('移动待付卡仅全宽继续支付按钮可打开原订单，连点不叠加', (
    tester,
  ) async {
    final pending = _order('TRADE-409-REAL', '待付套餐', XbOrderStatus.pending);
    final service = _serviceWith([pending]);
    when(() => service.getOrder(pending.tradeNo)).thenAnswer(
      (_) async => const XbSuccess<OrderDetail?>(null),
    );
    await _pumpOrders(tester, service);

    final summary = find.text('待付套餐', findRichText: true);
    final button = find.widgetWithText(FilledButton, '继续支付');
    expect(find.descendant(of: button, matching: find.byType(Icon)), findsNothing);
    final card = find.ancestor(of: button, matching: find.byType(XbCard));
    final cardRect = tester.getRect(card);
    final buttonRect = tester.getRect(button);
    // 按钮铺满卡片内容区：每边 1 px 卡片边框 + 13 px 按钮内距。
    const inset = 1.0 + 13.0;
    expect(buttonRect.left, cardRect.left + inset);
    expect(buttonRect.right, cardRect.right - inset);
    expect(
      tester.getTopLeft(button).dy,
      greaterThan(tester.getBottomLeft(summary).dy),
    );
    await tester.tap(summary);
    await tester.pumpAndSettle();
    expect(find.byType(OrderPaymentPage), findsNothing);
    verifyNever(() => service.getOrder(any()));

    await tester.tap(button);
    await tester.tap(button, warnIfMissed: false);
    await tester.pumpAndSettle();
    final detail = tester.widget<OrderPaymentPage>(
      find.byType(OrderPaymentPage, skipOffstage: false),
    );
    expect(detail.tradeNo, pending.tradeNo);
    verify(() => service.getOrder(pending.tradeNo)).called(1);
  });

  final first = _order('TRADE-OLD', '第一条记录', XbOrderStatus.completed)
      .copyWith(createdAt: DateTime(2026, 4, 30));
  final second = _order('TRADE-NEW', '第二条记录', XbOrderStatus.cancelled);
  final third = _order('TRADE-PROC', '第三条记录', XbOrderStatus.processing);

  testWidgets('移动历史订单同卡分隔，保持服务顺序及原订单详情入口', (
    tester,
  ) async {
    final service = _serviceWith([first, second, third]);
    when(() => service.getOrder(second.tradeNo)).thenAnswer(
      (_) async => const XbSuccess<OrderDetail?>(null),
    );
    await _pumpOrders(tester, service);

    final group = find.byType(DecoratedSliver);
    expect(group, findsOneWidget);
    expect(find.text('继续支付'), findsNothing);
    expect(
      find.descendant(of: group, matching: find.byType(Divider)),
      findsNWidgets(2),
    );
    expect(
      find.descendant(of: group, matching: find.byType(Icon)),
      findsNothing,
    );
    final firstRow = find.text('第一条记录', findRichText: true);
    final secondRow = find.text('第二条记录', findRichText: true);
    final thirdRow = find.text('第三条记录', findRichText: true);
    expect(
      tester.getTopLeft(firstRow).dy,
      lessThan(tester.getTopLeft(secondRow).dy),
    );
    expect(
      tester.getTopLeft(secondRow).dy,
      lessThan(tester.getTopLeft(thirdRow).dy),
    );

    await tester.tap(secondRow);
    await tester.pumpAndSettle();
    expect(
      tester.widget<OrderPaymentPage>(find.byType(OrderPaymentPage)).tradeNo,
      second.tradeNo,
    );
    verify(() => service.getOrder(second.tradeNo)).called(1);
  });

  testWidgets('宽窗口历史订单维持两列，奇数末项仍在左列', (tester) async {
    await _pumpOrders(tester, _serviceWith([first, second, third]), width: 1000);

    final a = tester.getTopLeft(find.text('第一条记录', findRichText: true));
    final b = tester.getTopLeft(find.text('第二条记录', findRichText: true));
    final c = tester.getTopLeft(find.text('第三条记录', findRichText: true));
    expect(a.dy, b.dy);
    expect(a.dx, lessThan(b.dx));
    expect(c.dx, a.dx);
    expect(c.dy, greaterThan(a.dy));
  });
}
