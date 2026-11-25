import 'package:fl_clash/ui/qr_code.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:fl_clash/xboard/models/checkout_outcome_ui.dart';
import 'package:fl_clash/xboard/models/order_summary.dart';
import 'package:fl_clash/xboard/models/xb_domain_error.dart';
import 'package:fl_clash/xboard/models/xb_domain_subscription.dart';
import 'package:fl_clash/xboard/models/xb_domain_types.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/pages/order_payment_page.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/providers/network_recovery_provider.dart';
import 'package:fl_clash/xboard/providers/user_profile_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/sdk/xboard_service.dart';
import 'package:fl_clash/xboard/services/xboard_subscription_service.dart';

OrderDetail order(
  XbOrderStatus status, {
  String tradeNo = 'T1',
  String plan = '标准套餐',
  double totalAmountYuan = 40,
}) => OrderDetail(
  summary: OrderSummary(
    tradeNo: tradeNo,
    planName: plan,
    period: XbPlanPeriod.quarterly,
    totalAmountYuan: totalAmountYuan,
    status: status,
    createdAt: DateTime(2026, 10, 12, 12, 30),
  ),
);

class _Service extends Mock implements XboardService {
  int reads = 0;
  int methodsReads = 0;
  int subscriptionReads = 0;
  int checkouts = 0;
  int cancellations = 0;
  final trades = <String>[];
  final checkoutMethods = <String>[];
  Future<XbResult<OrderDetail?>> Function(String)? onRead;
  Future<XbResult<List<PaymentMethodItem>>> Function()? onMethods;
  Future<XbResult<CheckoutOutcomeUi>> Function()? onCheckout;
  Future<XbResult<bool>> Function()? onCancel;

  @override
  Future<XbResult<OrderDetail?>> getOrder(String tradeNo) {
    ++reads;
    trades.add(tradeNo);
    return onRead?.call(tradeNo) ??
        Future.value(
          XbResult.success(order(XbOrderStatus.pending, tradeNo: tradeNo)),
        );
  }

  @override
  Future<XbResult<List<PaymentMethodItem>>> getPaymentMethods() {
    ++methodsReads;
    return onMethods?.call() ??
        Future.value(
          XbResult.success(const [
            PaymentMethodItem(id: 'alipay', name: '支付宝'),
          ]),
        );
  }

  @override
  Future<XbResult<CheckoutOutcomeUi>> checkout(String tradeNo, String method) {
    ++checkouts;
    checkoutMethods.add(method);
    return onCheckout?.call() ??
        Future.value(XbResult.success(const CheckoutPaid()));
  }

  @override
  Future<XbResult<bool>> cancelOrder(String tradeNo) {
    ++cancellations;
    return onCancel?.call() ?? Future.value(XbResult.success(true));
  }

  @override
  Future<XbResult<XbDomainSubscription>> getSubscription() async {
    ++subscriptionReads;
    return XbResult.success(
      const XbDomainSubscription(
        email: 'test@example.invalid',
        uuid: 'fixture',
        totalBytes: 1,
        usedBytes: 0,
      ),
    );
  }
}

class _Subscription extends Mock implements XboardSubscriptionService {
  int calls = 0;
  final forces = <bool>[];
  @override
  Future<XbSyncOutcome> sync({bool force = false}) async {
    forces.add(force);
    ++calls;
    return XbSyncOutcome.ok;
  }
}

class _Ready extends BootstrapReady {
  @override
  bool build() => true;
}

class _Auth extends AuthStateNotifier {
  @override
  AuthState build() => AuthState.authenticated;
  void change(AuthState next) => state = next;
}

class _Harness {
  final service = _Service();
  final subscription = _Subscription();
  final auth = _Auth();
  late final ProviderContainer container = ProviderContainer(
    overrides: [
      xboardServiceProvider.overrideWithValue(service),
      subscriptionServiceProvider.overrideWithValue(subscription),
      bootstrapReadyProvider.overrideWith(_Ready.new),
      authStateProvider.overrideWith(() => auth),
    ],
  );
  ProviderSubscription<AsyncValue<XbDomainSubscription>>? profile;
  bool mounted = false;

  Future<void> mount(
    WidgetTester tester, {
    String tradeNo = 'T1',
    Size size = const Size(390, 844),
    Brightness brightness = Brightness.light,
    double textScale = 1,
    double? panelWidth,
  }) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    profile ??= container.listen(
      userProfileProvider,
      (_, _) {},
      fireImmediately: true,
    );
    mounted = true;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: ThemeData(brightness: brightness),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: panelWidth,
              child: OrderPaymentPage(
                key: const ValueKey('payment'),
                tradeNo: tradeNo,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }

  Future<void> unmount(WidgetTester tester) async {
    if (mounted) {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      mounted = false;
    }
  }

  Future<void> close(WidgetTester tester) async {
    await unmount(tester);
    profile?.close();
    container.dispose();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  }
}

void _paymentTest(
  String name,
  Future<void> Function(WidgetTester, _Harness) run,
) {
  testWidgets(name, (tester) async {
    final harness = _Harness();
    try {
      await run(tester, harness);
      expect(harness.subscription.forces, everyElement(isTrue));
    } finally {
      await harness.close(tester);
    }
  });
}

Future<void> tap(WidgetTester tester, String label) async {
  final buttons = find
      .ancestor(
        of: text(label),
        matching: find.byWidgetPredicate(
          (widget) => widget is ButtonStyleButton,
        ),
      );
  if (buttons.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      text(label),
      200,
      scrollable: find.byType(Scrollable).first,
    );
  }
  final button = buttons.first;
  await tester.ensureVisible(button);
  await tester.pump();
  await tester.tap(button);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
}

Finder text(String label) => find.text(label, findRichText: true);

void main() {
  for (final (status, label) in [
    (XbOrderStatus.pending, '待支付'), (XbOrderStatus.processing, '开通中'),
    (XbOrderStatus.completed, '已完成'), (XbOrderStatus.cancelled, '已取消'),
    (XbOrderStatus.discounted, '已折抵'),
  ]) {
    _paymentTest('compact order header: $label', (t, h) async {
      h.service.onRead = (_) async => XbResult.success(order(status));
      await h.mount(t);
      expect(find.descendant(of: find.byType(AppBar), matching: text(label)), findsOneWidget);
      expect(text('套餐内容'), findsOneWidget);
      expect(text('标准套餐 · 季付'), findsOneWidget);
      expect(text('周期'), findsNothing);
    });
  }
  for (final cancel in [false, true]) {
    _paymentTest('${cancel ? "cancel" : "checkout"} shows a centered busy label only on its own button', (t,h) async {
      await h.mount(t);
      final checkoutGate = Completer<XbResult<CheckoutOutcomeUi>>();
      final cancelGate = Completer<XbResult<bool>>();
      h.service.onCheckout = () => checkoutGate.future;
      h.service.onCancel = () => cancelGate.future;
      await tap(t, cancel ? '取消订单' : '立即支付');
      if (cancel) await tap(t, '确定取消');
      final label = cancel ? '正在取消…' : '正在支付…';
      final button = cancel ? find.widgetWithText(OutlinedButton,label) : find.widgetWithText(FilledButton,label);
      expect(t.widget<ButtonStyleButton>(button).onPressed,isNull);
      expect(t.getCenter(text(label)).dx, closeTo(t.getCenter(button).dx, 1));
      expect(find.descendant(of:button,matching:find.byType(CircularProgressIndicator)),findsNothing);
      expect(text(cancel ? '立即支付' : '取消订单'),findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, '支付状态检查中'),findsNothing);
      if (cancel) {
        cancelGate.complete(const XbSuccess(false));
      } else {
        checkoutGate.complete(const XbSuccess(CheckoutCanceled()));
      }
      await t.pumpAndSettle();
      expect(text(label),findsNothing);
      expect(h.service.cancellations, cancel ? 1 : 0);
      expect(h.service.checkouts, cancel ? 0 : 1);
    });
  }
  _paymentTest('detail remains visible during channel load; verified recovery only retries reads', (t,h) async {
    final methods = Completer<XbResult<List<PaymentMethodItem>>>();
    h.service.onMethods = () => methods.future;
    await h.mount(t);
    expect(text('标准套餐 · 季付'), findsOneWidget);
    expect(text('正在加载支付方式…'), findsOneWidget);
    final pay = find.widgetWithText(FilledButton, '立即支付');
    expect(t.widget<FilledButton>(pay).onPressed, isNull);
    methods.complete(const XbFailure(XbNetwork(XbNetworkKind.timeout, 'fixture')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 350));
    h.service.onRead = (_) async => const XbFailure(XbNetwork(XbNetworkKind.timeout, 'fixture'));
    await tap(t, '检查支付状态');
    final reads = h.service.reads;
    await t.pump(const Duration(seconds: 12));
    expect(h.service.reads, reads);
    h.service.onRead = (_) async => XbSuccess(order(XbOrderStatus.pending));
    h.service.onMethods = null;
    h.container.read(networkRecoveryProvider.notifier).publish();
    await t.pumpAndSettle();
    expect(h.service.reads, reads + 1);
    expect(h.service.methodsReads, 2);
    expect(t.widget<FilledButton>(pay).onPressed, isNotNull);
    expect(h.service.checkouts, 0);
    expect(h.service.cancellations, 0);
    final profileReads = h.service.subscriptionReads;
    await h.unmount(t);
    expect(h.service.subscriptionReads, profileReads);
  });

  _paymentTest('business denial on order load is not retried by network recovery', (t,h) async {
    h.service.onRead = (_) async => const XbFailure(XbUnauthorized('fixture'));
    await h.mount(t);
    h.container.read(networkRecoveryProvider.notifier).publish();
    await t.pumpAndSettle();
    expect(h.service.reads, 1);
    expect(h.service.methodsReads, 0);
    expect(h.service.checkouts, 0);
  });

  _paymentTest('recovery does not load channels for a pending order that was cancelled remotely', (t,h) async {
    h.service.onMethods = () async => const XbFailure(XbNetwork(XbNetworkKind.timeout, 'fixture'));
    await h.mount(t);
    expect(text('支付方式加载失败'), findsOneWidget);
    h.service.onRead = (_) async => XbSuccess(order(XbOrderStatus.cancelled));
    h.container.read(networkRecoveryProvider.notifier).publish();
    await t.pumpAndSettle();
    expect(text('已取消'), findsOneWidget);
    expect(text('立即支付'), findsNothing);
    expect(h.service.methodsReads, 1);
    expect(h.service.checkouts, 0);
    expect(h.service.cancellations, 0);
    expect(h.subscription.calls, 0);
  });
  for (final missing in [true, false]) {
    _paymentTest(
      'invalid detail (${missing ? 'missing' : 'wrong order'}) preserves previous order',
      (t, h) async {
        await h.mount(t);
        h.service.onRead = (_) async => XbResult.success(
          missing
              ? null
              : order(XbOrderStatus.completed, tradeNo: 'another-order'),
        );
        await tap(t, '检查支付状态');
        expect(text('待支付'), findsOneWidget);
        expect(text('检测失败'), findsOneWidget);
        expect(text('检查支付状态'), findsOneWidget);
        expect(h.subscription.calls, 0);
      },
    );
  }

  _paymentTest('桌面终态应付金额含已记账手续费，不重复应用优惠', (t, h) async {
    final detail = order(XbOrderStatus.completed).copyWith(
      discountAmountYuan: 5,
      handlingAmountYuan: 1.25,
    );
    h.service.onRead = (_) async => XbResult.success(detail);
    await h.mount(t, size: const Size(1200, 800));
    expect(text('抵扣前订单金额'), findsOneWidget);
    expect(text('¥45.00'), findsOneWidget);
    expect(text('订单优惠（已抵扣）'), findsOneWidget);
    expect(text('-¥5.00'), findsOneWidget);
    expect(text('支付手续费'), findsOneWidget);
    expect(text('¥41.25'), findsOneWidget);
    expect(text('应付金额'), findsOneWidget);
    expect(h.service.checkouts, 0);
  });

  for (final state in [XbOrderStatus.pending, XbOrderStatus.completed]) {
    _paymentTest('signed channel adjustment preserved: $state', (t, h) async {
      final detail = order(state, totalAmountYuan: 10).copyWith(handlingAmountYuan: -1);
      h.service.onRead = (_) async => XbSuccess(detail);
      h.service.onMethods = () async => const XbSuccess([PaymentMethodItem(id: 'promo', name: '优惠渠道', feeFixedYuan: -1)]);
      await h.mount(t, size: const Size(390, 1200));
      expect(text('-¥1.00'), findsOneWidget);
      expect(text('¥9.00'), findsOneWidget);
      if (state == XbOrderStatus.pending) expect(text('手续费 -¥1.00'), findsOneWidget);
    });
  }
  _paymentTest('mobile pending amount follows the selected channel', (t, h) async {
    final detail = order(XbOrderStatus.pending, totalAmountYuan: 2).copyWith(
      balanceAmountYuan: 1,
      discountAmountYuan: 0.5,
      handlingAmountYuan: 0.9,
    );
    h.service.onRead = (_) async => XbResult.success(detail);
    h.service.onMethods = () async => const XbSuccess([
      PaymentMethodItem(
        id: 'paid',
        name: '混合手续费渠道',
        feePercent: 6.25,
        feeFixedYuan: 0.03,
      ),
      PaymentMethodItem(id: 'rate', name: '比例手续费渠道', feePercent: 2),
      PaymentMethodItem(id: 'fixed', name: '固定手续费渠道', feeFixedYuan: 0.8),
      PaymentMethodItem(id: 'free', name: '免手续费渠道'),
    ]);
    await h.mount(t, size: const Size(390, 1200));
    expect(text('抵扣前订单金额'), findsOneWidget);
    expect(text('¥3.50'), findsOneWidget);
    expect(text('余额抵扣'), findsOneWidget);
    expect(text('-¥1.00'), findsOneWidget);
    expect(text('支付手续费'), findsOneWidget);
    expect(text('¥0.16'), findsOneWidget); // 200 分 × 6.25% + 3 分 → 16 分
    expect(text('应付金额'), findsOneWidget);
    expect(text('¥2.16'), findsOneWidget);
    expect(text('订单优惠（已抵扣）'), findsOneWidget);
    expect(text('-¥0.50'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
    expect(text('手续费 6.25% + ¥0.03'), findsOneWidget);
    expect(text('手续费 2%'), findsOneWidget);
    expect(text('手续费 ¥0.80'), findsOneWidget);
    expect(text('免手续费'), findsOneWidget);

    final rate = text('比例手续费渠道');
    await t.ensureVisible(rate);
    await t.pump();
    await t.tap(rate);
    await t.pump();
    final selectedRow = find.ancestor(of: rate, matching: find.byType(InkWell)).first;
    expect(find.descendant(of: selectedRow, matching: find.byIcon(Icons.check_circle_outline)), findsOneWidget);
    expect(text('¥0.04'), findsOneWidget);
    expect(text('¥2.04'), findsOneWidget);

    final free = text('免手续费渠道');
    await t.ensureVisible(free);
    await t.pump();
    await t.tap(free);
    await t.pump();
    expect(text('支付手续费'), findsNothing);
    expect(text('¥0.16'), findsNothing);
    expect(text('¥0.90'), findsNothing);
    expect(text('¥2.00'), findsOneWidget);
    expect(h.service.checkouts, 0);

    // 切换到已完成后，详情中的已记账手续费覆盖当前渠道的预估。
    h.service.onRead = (_) async => XbResult.success(
      detail.copyWith(
        summary: detail.summary.copyWith(status: XbOrderStatus.completed),
        handlingAmountYuan: 0.23,
      ),
    );
    await tap(t, '检查支付状态');
    expect(text('支付手续费'), findsOneWidget);
    expect(text('¥0.23'), findsOneWidget);
    expect(text('¥2.23'), findsOneWidget);
    expect(h.service.checkouts, 0);
  });

  for (final amount in <double?>[null, 0]) {
    _paymentTest(
      'mobile detail hides absent or zero amounts ($amount)',
      (t, h) async {
        final detail = order(
          XbOrderStatus.completed,
          totalAmountYuan: 2,
        ).copyWith(balanceAmountYuan: amount, handlingAmountYuan: amount, discountAmountYuan: amount);
        h.service.onRead = (_) async => XbResult.success(detail);
        await h.mount(t);
        expect(text('订单金额'), findsOneWidget);
        expect(text('应付金额'), findsOneWidget);
        expect(text('¥2.00'), findsNWidgets(2));
        expect(text('余额抵扣'), findsNothing);
        expect(text('订单优惠（已抵扣）'), findsNothing);
        expect(text('抵扣前订单金额'), findsNothing);
        expect(text('支付手续费'), findsNothing);
        expect(h.service.methodsReads, 0);
      },
    );
  }

  for (final status in [XbOrderStatus.pending, XbOrderStatus.completed]) {
    for (final scenario in <(String, double, double, double?, double?, double?)>[
      // Net, balance, reported excess, effective surplus deduction, subtotal.
      ('partial', 60, 10, null, 20, 100),
      ('balance covers rest', 0, 10, null, 20, 40),
      ('exact', 0, 0, 0, 20, 30),
      ('excess', 0, 0, 7, 13, 23),
      ('no new charge', 0, 0, 20, 0, 10),
      ('missing credit', 0, 0, null, null, null),
      ('credit exceeds surplus', 0, 0, 23, null, null),
    ]) {
      _paymentTest('order deductions: $status ${scenario.$1}', (t, h) async {
        final (_, net, balance, credit, applied, subtotal) = scenario;
        final detail = order(status, totalAmountYuan: net).copyWith(
          balanceAmountYuan: balance,
          discountAmountYuan: 10,
          surplusAmountYuan: 20,
          surplusCreditYuan: credit,
          handlingAmountYuan: net > 0 ? 2 : 0,
        );
        h.service.onRead = (_) async => XbSuccess(detail);
        h.service.onMethods = () async => const XbSuccess([
          PaymentMethodItem(id: 'channel', name: '渠道', feeFixedYuan: 1),
        ]);
        await h.mount(t, size: const Size(390, 1200));
        void checkRow(String label, double? value, {bool minus = false}) {
          if (value == null) {
            expect(text(label), findsNothing);
            return;
          }
          final row = find.ancestor(of: text(label), matching: find.byType(Row)).first;
          expect(find.descendant(of: row, matching: text('${minus ? '-' : ''}¥${value.toStringAsFixed(2)}')), findsOneWidget);
        }
        checkRow('抵扣前订单金额', subtotal);
        checkRow('旧套餐结余抵扣', applied == 0 ? null : applied, minus: true);
        checkRow('旧套餐结余（抵扣额待核实）', applied == null ? 20 : null);
        checkRow('结余返还金额', credit == 0 ? null : credit);
        checkRow('订单优惠（已抵扣）', 10, minus: true);
        checkRow('余额抵扣', balance > 0 ? balance : null, minus: true);
        final fee = net > 0 ? (status == XbOrderStatus.pending ? 1.0 : 2.0) : 0.0;
        checkRow('应付金额', net + fee);
        expect(h.service.checkouts, 0);
      });
    }
  }

  _paymentTest('mobile pending without channels does not reuse a recorded fee', (
    t,
    h,
  ) async {
    final detail = order(XbOrderStatus.pending, totalAmountYuan: 2).copyWith(
      balanceAmountYuan: 1,
      handlingAmountYuan: 0.9,
    );
    h.service.onRead = (_) async => XbResult.success(detail);
    h.service.onMethods = () async => const XbSuccess(<PaymentMethodItem>[]);
    await h.mount(t);
    expect(text('暂无可用支付方式'), findsOneWidget);
    expect(text('支付手续费'), findsNothing);
    expect(text('¥2.00'), findsOneWidget);
  });

  _paymentTest('mobile zero-payable order does not incur a fixed channel fee', (
    t,
    h,
  ) async {
    final detail = order(XbOrderStatus.pending, totalAmountYuan: 0).copyWith(
      balanceAmountYuan: 3,
    );
    h.service.onRead = (_) async => XbResult.success(detail);
    h.service.onMethods = () async => const XbSuccess([
      PaymentMethodItem(id: 'paid', name: '收费渠道', feeFixedYuan: 0.16),
    ]);
    await h.mount(t);
    expect(text('余额抵扣'), findsOneWidget);
    expect(text('-¥3.00'), findsOneWidget);
    expect(text('支付手续费'), findsNothing);
    expect(text('免手续费'), findsOneWidget);
    expect(text('¥0.00'), findsOneWidget);
  });

  _paymentTest('discounted status refreshes once and stops polling', (
    t,
    h,
  ) async {
    await h.mount(t);
    h.service.onRead = (_) async =>
        XbResult.success(order(XbOrderStatus.discounted));
    await tap(t, '检查支付状态');
    expect(text('订单已折抵'), findsOneWidget);
    expect(h.subscription.calls, 1);
    await t.pump(const Duration(seconds: 12));
    expect(h.service.reads, 2);
    expect(h.subscription.calls, 1);
  });

  for (final failure in ['unavailable', 'denied', 'launch-error', 'probe-error']) {
    _paymentTest('external launch failure: $failure', (t, h) async {
      const channel = MethodChannel('plugins.flutter.io/url_launcher');
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final attempts = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        attempts.add(call.method);
        if (call.method == 'canLaunch') {
          if (failure == 'probe-error') throw PlatformException(code: 'query_failed');
          return failure != 'unavailable';
        }
        if (failure == 'launch-error') throw PlatformException(code: 'activity_gone');
        return false;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await h.mount(t);
      h.service.onCheckout = () async => const XbSuccess(CheckoutRedirect('https://example.invalid/pay'));
      await tap(t, '立即支付');
      expect(text('无法打开支付页面'), findsOneWidget);
      expect(text('已打开支付页面，完成后返回点「检查支付状态」'), findsNothing);
      expect(h.service.checkouts, 1);
      expect(attempts.where((m) => m == 'launch'), hasLength(['denied','launch-error'].contains(failure) ? 1 : 0));
      expect(t.takeException(), isNull);
      await t.pump(const Duration(seconds: 4));
    });
  }

  for (final early in [true, false]) {
    for (final result in ['pending', 'completed', 'failed']) {
      _paymentTest('return check before unlocking payment (early=$early, result=$result)', (t, h) async {
        const channel = MethodChannel('plugins.flutter.io/url_launcher');
        final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        final launched = Completer<bool>();
        messenger.setMockMethodCallHandler(channel, (call) async => call.method == 'launch' ? launched.future : true);
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        await h.mount(t);
        h.service.onCheckout = () async => const XbSuccess(CheckoutRedirect('https://example.invalid/pay'));
        await tap(t, '立即支付');
        final response = Completer<XbResult<OrderDetail?>>();
        h.service.onRead = (_) => response.future;
        t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        if (early) t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        launched.complete(true);
        await t.pump();
        if (!early) t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await t.pump();
        expect(h.service.reads, 2, reason: 'return check must not wait for the poll timer');
        final pay = find.widgetWithText(FilledButton, '立即支付');
        final cancel = find.widgetWithText(OutlinedButton, '取消订单');
        expect(t.widget<FilledButton>(pay).onPressed, isNull);
        expect(t.widget<OutlinedButton>(cancel).onPressed, isNull);
        response.complete(result == 'failed' ? const XbFailure(XbServer(503, 'offline')) :
            XbSuccess(order(result == 'completed' ? XbOrderStatus.completed : XbOrderStatus.pending)));
        await t.pump();
        await t.pump(const Duration(milliseconds: 350));
        if (result == 'completed') {
          expect(text('已完成'), findsOneWidget);
          expect(pay, findsNothing);
        } else {
          expect(t.widget<FilledButton>(pay).onPressed != null, result == 'pending');
          if (result == 'failed') expect(text('检查支付状态'), findsOneWidget);
        }
        expect(h.service.checkouts, 1);
        await t.pump(const Duration(seconds: 4));
      });
    }
  }

  _paymentTest(
    'external payment return queries status without inferring payment from launch',
    (t, h) async {
      const channel = MethodChannel('plugins.flutter.io/url_launcher');
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return true;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      await h.mount(t);
      h.service.onCheckout = () async => XbResult.success(
        const CheckoutRedirect('https://example.invalid/pay'),
      );
      await tap(t, '立即支付');
      expect(calls.map((call) => call.method), contains('launch'));
      expect(h.subscription.calls, 0);
      expect(text('待支付'), findsOneWidget);
      h.service.onRead = (_) async =>
          XbResult.success(order(XbOrderStatus.completed));
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await t.pump();
      await t.pump(const Duration(milliseconds: 350));
      expect(text('已完成'), findsOneWidget);
      expect(h.subscription.calls, 1);
    },
  );
  _paymentTest(
    'manual detection shows busy, leaves other actions enabled, and shares slow request',
    (t, h) async {
      await h.mount(t);
      final response = Completer<XbResult<OrderDetail?>>();
      h.service.onRead = (_) => response.future;
      await tap(t, '检查支付状态');
      expect(text('支付状态检查中'), findsOneWidget);
      final busyCheck = find.widgetWithText(OutlinedButton, '支付状态检查中');
      expect(busyCheck, findsOneWidget);
      expect(find.descendant(of: busyCheck, matching: find.byType(CircularProgressIndicator)), findsNothing);
      expect(find.descendant(of: busyCheck, matching: find.byIcon(Icons.hourglass_empty_rounded)), findsOneWidget);
      expect(t.widget<OutlinedButton>(busyCheck).onPressed, isNull);
      for (final label in ['立即支付', '取消订单']) {
        final action = find.ancestor(of: text(label), matching: find.byWidgetPredicate((w) => w is ButtonStyleButton)).first;
        expect(t.widget<ButtonStyleButton>(action).onPressed, isNotNull);
      }
      await tap(t, '支付状态检查中');
      await t.pump(const Duration(seconds: 12));
      expect(h.service.reads, 2);
      response.complete(XbResult.success(order(XbOrderStatus.pending)));
      await t.pump();
      await t.pump(const Duration(milliseconds: 250));
      expect(text('订单仍待支付'), findsOneWidget);
      expect(text('若已完成付款，请稍后再试。'), findsOneWidget);
      expect(text('检查支付状态'), findsOneWidget);
      expect(h.subscription.calls, 0);
    },
  );

  _paymentTest(
    'manual query joins polling and completion refreshes exactly once',
    (t, h) async {
      await h.mount(t);
      await t.pump(const Duration(seconds: 10));
      expect(h.service.reads, 1, reason: 'opening a pending order does not start the payment watch');
      h.service.onCheckout = () async => const XbSuccess(CheckoutCanceled());
      await tap(t, '立即支付');
      final accountsBefore = h.service.subscriptionReads;
      final response = Completer<XbResult<OrderDetail?>>();
      h.service.onRead = (_) => response.future;
      await t.pump(const Duration(seconds: 5));
      expect(h.service.reads, 2);
      expect(find.widgetWithText(OutlinedButton, '支付状态检查中'), findsOneWidget);
      await tap(t, '支付状态检查中');
      await t.pump(const Duration(seconds: 10));
      expect(h.service.reads, 2);
      response.complete(XbResult.success(order(XbOrderStatus.completed)));
      await t.pump();
      await t.pump(const Duration(milliseconds: 350));
      expect(text('已完成'), findsOneWidget);
      expect(text('支付成功'), findsOneWidget);
      expect(text('立即支付'), findsNothing);
      expect(h.subscription.calls, 1);
      expect(h.service.subscriptionReads, accountsBefore + 1);
      await t.pump(const Duration(seconds: 12));
      expect(h.service.reads, 2);
      expect(h.subscription.calls, 1);
    },
  );

  _paymentTest('failed query keeps pending and retry can enter opening state', (
    t,
    h,
  ) async {
    await h.mount(t);
    h.service.onRead = (_) async =>
        XbResult.failure(const XbNetwork(XbNetworkKind.timeout, 'timeout'));
    await tap(t, '检查支付状态');
    expect(text('检测失败'), findsOneWidget);
    expect(text('待支付'), findsOneWidget);
    expect(text('检查支付状态'), findsOneWidget);
    expect(t.widget<FilledButton>(find.widgetWithText(FilledButton, '立即支付')).onPressed, isNull);
    expect(t.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '取消订单')).onPressed, isNull);
    h.service.onRead = (_) async =>
        XbResult.success(order(XbOrderStatus.processing));
    await tap(t, '检查支付状态');
    expect(text('开通中'), findsNWidgets(2));
    expect(text('付款已确认，正在开通服务，请勿重复支付。'), findsOneWidget);
    expect(text('立即支付'), findsNothing);
    expect(find.widgetWithText(OutlinedButton, '取消订单'), findsNothing);
    expect(text('检查支付状态'), findsOneWidget);
    expect(h.subscription.calls, 0);
  });

  _paymentTest('opening survives failed query and a stale pending response', (
    t,
    h,
  ) async {
    h.service.onRead = (_) async =>
        XbResult.success(order(XbOrderStatus.processing));
    await h.mount(t);
    h.service.onRead = (_) async =>
        XbResult.failure(const XbServer(503, 'unavailable'));
    await tap(t, '检查支付状态');
    expect(text('开通中'), findsOneWidget);
    expect(text('检测失败'), findsOneWidget);
    h.service.onRead = (_) async =>
        XbResult.success(order(XbOrderStatus.pending));
    await tap(t, '检查支付状态');
    expect(text('开通中'), findsNWidgets(2));
    expect(text('待支付'), findsNothing);
    expect(text('立即支付'), findsNothing);
  });

  _paymentTest(
    'cancelled query stops polling without subscription or account completion refresh',
    (t, h) async {
      await h.mount(t);
      final accountsBefore = h.service.subscriptionReads;
      h.service.onRead = (_) async =>
          XbResult.success(order(XbOrderStatus.cancelled));
      await tap(t, '检查支付状态');
      expect(text('已取消'), findsOneWidget);
      expect(text('订单已取消'), findsWidgets);
      expect(text('支付成功'), findsNothing);
      expect(h.subscription.calls, 0);
      expect(h.service.subscriptionReads, accountsBefore);
      await t.pump(const Duration(seconds: 12));
      expect(h.service.reads, 2);
    },
  );

  _paymentTest('successful cancellation rejects its old polling response', (
    t,
    h,
  ) async {
    await h.mount(t);
      h.service.onCheckout = () async => const XbSuccess(CheckoutCanceled());
      await tap(t, '立即支付');
    final response = Completer<XbResult<OrderDetail?>>();
    h.service.onRead = (_) => h.service.reads == 2
        ? response.future
        : Future.value(XbResult.success(order(XbOrderStatus.cancelled)));
    await t.pump(const Duration(seconds: 5));
    await tap(t, '取消订单');
    await t.pump(const Duration(milliseconds: 250));
    await tap(t, '确定取消');
    await t.pump(const Duration(milliseconds: 250));
    expect(text('已取消'), findsOneWidget);
    expect(h.service.cancellations, 1);
    expect(h.subscription.calls, 0);
    response.complete(XbResult.success(order(XbOrderStatus.pending)));
    await t.pump();
    await t.pump(const Duration(milliseconds: 350));
    expect(text('已取消'), findsOneWidget);
    expect(text('待支付'), findsNothing);
    expect(h.service.reads, 3);
    expect(h.subscription.calls, 0);
    await t.pump(const Duration(seconds: 12));
    expect(h.service.reads, 3);
  });

  _paymentTest(
    'free checkout waits for fresh detail and deduplicates completion',
    (t, h) async {
      await h.mount(t);
      final old = Completer<XbResult<OrderDetail?>>();
      h.service.onRead = (_) => h.service.reads == 2
          ? old.future
          : Future.value(XbResult.success(order(XbOrderStatus.completed)));
      final checkout = Completer<XbResult<CheckoutOutcomeUi>>();
      h.service.onCheckout = () => checkout.future;
      await tap(t, '立即支付');
      await t.pump(const Duration(seconds: 5));
      checkout.complete(const XbSuccess(CheckoutPaid()));
      await t.pump();
      expect(h.service.checkouts, 1);
      expect(h.service.reads, 2);
      expect(h.subscription.calls, 0);
      old.complete(XbResult.success(order(XbOrderStatus.completed)));
      await t.pump();
      await t.pump(const Duration(milliseconds: 350));
      expect(h.service.reads, 3);
      expect(h.subscription.calls, 1);
      expect(text('已完成'), findsOneWidget);
      await t.pump(const Duration(seconds: 12));
      expect(h.subscription.calls, 1);
      expect(h.service.reads, 3);
    },
  );

  _paymentTest('first load error clears after successful retry', (t, h) async {
    h.service.onRead = (_) async =>
        XbResult.failure(const XbServer(503, '暂不可用'));
    await h.mount(t);
    expect(text('暂不可用'), findsOneWidget);
    h.service.onRead = (_) async =>
        XbResult.success(order(XbOrderStatus.pending));
    await tap(t, '重试');
    await t.pump(const Duration(milliseconds: 350));
    expect(text('暂不可用'), findsNothing);
    expect(text('待支付'), findsOneWidget);
    expect(text('标准套餐 · 季付'), findsOneWidget);
    expect(text('立即支付'), findsOneWidget);
  });

  _paymentTest(
    'payment methods failure remains local and reload does not refetch order',
    (t, h) async {
      h.service.onMethods = () async =>
          XbResult.failure(const XbServer(503, 'unavailable'));
      await h.mount(t);
      expect(text('标准套餐 · 季付'), findsOneWidget);
      expect(text('支付方式加载失败'), findsOneWidget);
      final pay = find.widgetWithText(FilledButton, '立即支付');
      expect(t.widget<FilledButton>(pay).onPressed, isNull);
      expect(h.service.checkouts, 0);
      h.service.onMethods = null;
      await tap(t, '重新加载');
      await t.pump(const Duration(milliseconds: 350));
      expect(text('支付方式加载失败'), findsNothing);
      expect(text('支付宝'), findsOneWidget);
      expect(t.widget<FilledButton>(pay).onPressed, isNotNull);
      expect(h.service.reads, 1);
    },
  );

  for (final leave in [false, true]) {
    _paymentTest('keyboard channel retry preserves focus intent (leave=$leave)', (t, h) async {
      h.service.onMethods = () async => XbResult.failure(const XbServer(503, 'offline'));
      await h.mount(t, size: const Size(1220, 850));
      final response = Completer<XbResult<List<PaymentMethodItem>>>();
      h.service.onMethods = () => response.future;
      Focus.of(t.element(find.text('重新加载'))).requestFocus();
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pump();
      expect(h.service.methodsReads, 2);
      expect(text('正在加载支付方式…'), findsOneWidget);
      expect(text('支付方式加载失败'), findsNothing);
      final pay = find.widgetWithText(FilledButton, '立即支付');
      expect(t.widget<FilledButton>(pay).onPressed, isNull);
      expect(find.descendant(of: pay, matching: find.byType(CircularProgressIndicator)), findsNothing);
      if (leave) FocusManager.instance.primaryFocus!.unfocus();
      await t.pump();
      response.complete(const XbSuccess([PaymentMethodItem(id: 'alipay', name: '支付宝')]));
      await t.pumpAndSettle();
      final method = t.widget<InkWell>(find.ancestor(of: text('支付宝'), matching: find.byType(InkWell)).first);
      expect(method.focusNode!.hasPrimaryFocus, !leave);
      expect(h.service.checkouts, 0);
    });
  }

  for (final brightness in Brightness.values) {
    _paymentTest('mobile channel retry stays centered, legible and exclusive: $brightness', (t, h) async {
      h.service.onMethods = () async => XbResult.failure(const XbServer(503, 'offline'));
      await h.mount(t, size: const Size(390, 1200), brightness: brightness);
      final retry = find.widgetWithText(FilledButton, '重新加载');
      final pay = find.widgetWithText(FilledButton, '立即支付');
      final cancel = find.widgetWithText(OutlinedButton, '取消订单');
      final check = find.widgetWithText(OutlinedButton, '检查支付状态');
      expect(t.getRect(check).top, greaterThan(t.getRect(pay).bottom));
      expect(t.getRect(cancel).top, greaterThan(t.getRect(check).bottom));
      expect(t.getSize(check).width, t.getSize(pay).width);
      final centerX = t.getCenter(pay).dx;
      expect(t.getCenter(retry).dx, closeTo(centerX, 1));
      expect(t.getCenter(text('支付方式加载失败')).dx, closeTo(centerX, 1));

      final response = Completer<XbResult<List<PaymentMethodItem>>>();
      h.service.onMethods = () => response.future;
      await tap(t, '重新加载');
      expect(t.getCenter(text('正在加载支付方式…')).dx, closeTo(centerX, 1));
      final busyRetry = find.widgetWithText(FilledButton, '正在加载…');
      expect(t.getCenter(text('正在加载…')).dx, closeTo(t.getCenter(busyRetry).dx, 1));
      expect(t.widget<FilledButton>(busyRetry).onPressed, isNull);
      expect(t.widget<Text>(find.text('正在加载…')).style?.color, Colors.white);
      expect(find.descendant(of: busyRetry, matching: find.byType(CircularProgressIndicator)), findsNothing);
      expect(text('正在支付…'), findsNothing);
      // Check the inherited text color and painted button background, rather
      // than assuming the theme's disabled defaults provide readable contrast.
      for (final entry in [(pay, '立即支付'), (cancel, '取消订单'), (check, '检查支付状态')]) {
        final (finder, label) = entry;
        final button = t.widget<ButtonStyleButton>(finder);
        expect(button.onPressed, isNull);
        final ink = DefaultTextStyle.of(t.element(find.text(label))).style.color!;
        final decoration = button is FilledButton
            ? t.widget<DecoratedBox>(find.ancestor(of: finder, matching: find.byType(DecoratedBox)).first).decoration as BoxDecoration
            : null;
        final backgrounds = decoration == null
            ? [button.style!.backgroundColor!.resolve({WidgetState.disabled})!]
            : decoration.gradient?.colors ?? [decoration.color!];
        for (final background in backgrounds) {
          final a = ink.computeLuminance(), b = background.computeLuminance();
          expect((a > b ? (a + .05) / (b + .05) : (b + .05) / (a + .05)), greaterThanOrEqualTo(4.5), reason: label);
        }
        await t.tap(finder);
      }
      expect(h.service.methodsReads, 2);
      expect(h.service.checkouts, 0);
      expect(h.service.cancellations, 0);
      expect(h.service.reads, 1);
      response.complete(const XbSuccess([PaymentMethodItem(id: 'alipay', name: '支付宝')]));
      await t.pumpAndSettle();
      for (final finder in [pay, cancel, check]) {
        expect(t.widget<ButtonStyleButton>(finder).onPressed, isNotNull);
      }
    });
  }

  _paymentTest('channel retry exception stays in the method card and allows retry', (t, h) async {
    h.service.onMethods = () async => XbResult.failure(const XbServer(503, 'offline'));
    await h.mount(t);
    h.service.onMethods = () async => throw StateError('channel offline');
    await tap(t, '重新加载');
    expect(text('支付方式加载失败'), findsOneWidget);
    expect(text('正在加载支付方式…'), findsNothing);
    expect(text('标准套餐 · 季付'), findsOneWidget);
    h.service.onMethods = null;
    await tap(t, '重新加载');
    await t.pumpAndSettle();
    expect(text('支付宝'), findsOneWidget);
    expect(h.service.reads, 1);
    expect(h.service.checkouts, 0);
  });

  _paymentTest('empty channel list cannot submit payment', (t, h) async {
    h.service.onMethods = () async => const XbSuccess([]);
    await h.mount(t);
    expect(t.widget<FilledButton>(find.widgetWithText(FilledButton, '立即支付')).onPressed, isNull);
    expect(h.service.checkouts, 0);
  });

  _paymentTest('absent and rejected channel icons do not prevent checkout', (
    t,
    h,
  ) async {
    h.service.onMethods = () async => const XbSuccess([
      PaymentMethodItem(id: 'first', name: 'First channel'),
      PaymentMethodItem(
        id: 'second',
        name: 'Second channel',
        icon: 'file:///not-a-network-icon.svg',
        feePercent: 0.5,
        feeFixedYuan: 0.1,
      ),
    ]);
    h.service.onCheckout = () async => const XbSuccess(CheckoutCanceled());
    await h.mount(t, size: const Size(1220, 850));
    expect(text('First channel'), findsOneWidget);
    expect(text('Second channel'), findsOneWidget);
    expect(text('手续费 0.5% + ¥0.10'), findsOneWidget);
    expect(text('免手续费'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is GlyphIcon && widget.glyph == AppGlyphs.photos,
      ),
      findsNWidgets(2),
    );
    await t.tap(text('Second channel'));
    await t.pump();
    await tap(t, '立即支付');
    expect(h.service.checkoutMethods, ['second']);
  });

  _paymentTest('missing order stops at empty state without polling', (
    t,
    h,
  ) async {
    h.service.onRead = (_) async => XbResult.success(null);
    await h.mount(t);
    expect(text('订单不存在'), findsOneWidget);
    await t.pump(const Duration(seconds: 12));
    expect(h.service.reads, 1);
  });

  _paymentTest('query exception releases manual loading and permits retry', (
    t,
    h,
  ) async {
    await h.mount(t);
    h.service.onRead = (_) => throw StateError('fixture failure');
    await tap(t, '检查支付状态');
    expect(find.widgetWithText(OutlinedButton, '支付状态检查中'), findsNothing);
    expect(text('检查支付状态'), findsOneWidget);
    expect(text('检测失败'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  _paymentTest(
    'asynchronous query rejection releases the shared request for retry',
    (t, h) async {
      await h.mount(t);
      final response = Completer<XbResult<OrderDetail?>>();
      h.service.onRead = (_) => response.future;
      await tap(t, '检查支付状态');
      response.completeError(StateError('controlled asynchronous failure'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 350));
      expect(text('检查支付状态'), findsOneWidget);
      expect(t.takeException(), isNull);
      final previous = h.service.reads;
      h.service.onRead = (_) async =>
          XbResult.success(order(XbOrderStatus.pending));
      await tap(t, '检查支付状态');
      expect(h.service.reads, previous + 1);
      expect(t.widget<FilledButton>(find.widgetWithText(FilledButton, '立即支付')).onPressed, isNotNull);
      expect(t.takeException(), isNull);
    },
  );

  _paymentTest('disposed payment query consumes a late rejection', (
    t,
    h,
  ) async {
    await h.mount(t);
    final response = Completer<XbResult<OrderDetail?>>();
    h.service.onRead = (_) => response.future;
    await tap(t, '检查支付状态');
    await h.unmount(t);
    response.completeError(StateError('controlled disposed query failure'));
    await t.pump();
    expect(t.takeException(), isNull);
  });

  _paymentTest(
    'disposed page ignores late completion and removes its feedback',
    (t, h) async {
      await h.mount(t);
      final response = Completer<XbResult<OrderDetail?>>();
      h.service.onRead = (_) => response.future;
      await tap(t, '检查支付状态');
      await h.unmount(t);
      response.complete(XbResult.success(order(XbOrderStatus.completed)));
      await t.pump();
      expect(h.subscription.calls, 0);
      expect(t.takeException(), isNull);
    },
  );

  _paymentTest('account transitions invalidate a previous account response', (
    t,
    h,
  ) async {
    await h.mount(t);
    final response = Completer<XbResult<OrderDetail?>>();
    h.service.onRead = (_) => response.future;
    await tap(t, '检查支付状态');
    h.auth.change(AuthState.unauthenticated);
    h.auth.change(AuthState.authenticated);
    await t.pump();
    response.complete(
      XbResult.success(order(XbOrderStatus.completed, plan: '旧账号套餐')),
    );
    await t.pump();
    await t.pump(const Duration(milliseconds: 350));
    expect(text('旧账号套餐'), findsNothing);
    expect(text('已完成'), findsNothing);
    expect(h.subscription.calls, 0);
    expect(t.takeException(), isNull);
  });

  _paymentTest('new order rejects late response for old order', (t, h) async {
    await h.mount(t);
    final old = Completer<XbResult<OrderDetail?>>();
    h.service.onRead = (trade) => trade == 'T1'
        ? old.future
        : Future.value(
            XbResult.success(
              order(XbOrderStatus.pending, tradeNo: trade, plan: '新订单套餐'),
            ),
          );
    await tap(t, '检查支付状态');
    await h.mount(t, tradeNo: 'T2');
    old.complete(
      XbResult.success(order(XbOrderStatus.completed, plan: '旧订单套餐')),
    );
    await t.pump();
    await t.pump(const Duration(milliseconds: 350));
    expect(text('新订单套餐 · 季付'), findsOneWidget);
    expect(text('旧订单套餐 · 季付'), findsNothing);
    expect(h.subscription.calls, 0);
    expect(h.service.trades, contains('T2'));
  });

  _paymentTest(
    'background pauses polling and resume silently queries latest status',
    (t, h) async {
      await h.mount(t);
      h.service.onCheckout = () async => const XbSuccess(CheckoutCanceled());
      await tap(t, '立即支付');
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await t.pump(const Duration(seconds: 12));
      expect(h.service.reads, 1);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await t.pump();
      expect(h.service.reads, 2);
      expect(text('订单仍待支付'), findsNothing);
      await t.pump(const Duration(seconds: 5));
      expect(h.service.reads, 3);
    },
  );

  for (final status in [XbOrderStatus.cancelled, XbOrderStatus.completed, XbOrderStatus.discounted]) {
    _paymentTest('desktop centers $status order information within its panel', (t, h) async {
      h.service.onRead = (_) async => XbResult.success(order(status));
      await h.mount(t, size: const Size(1264, 800), panelWidth: 1064);
      final panel = t.getRect(find.byType(OrderPaymentPage));
      for (final label in ['套餐内容', '创建时间']) {
        final row = find.ancestor(of: text(label), matching: find.byType(Row)).first;
        expect(t.getCenter(row).dx, closeTo(panel.center.dx, 1));
      }
      expect(text('检查支付状态'), findsNothing);
    });
  }

  _paymentTest(
    'desktop opening keeps information and detection in two columns',
    (t, h) async {
      h.service.onRead = (_) async =>
          XbResult.success(order(XbOrderStatus.processing));
      await h.mount(t, size: const Size(1200, 800));
      expect(text('开通中'), findsOneWidget);
      expect(
        t.getTopLeft(text('套餐内容')).dx,
        lessThan(t.getTopLeft(text('检查支付状态')).dx),
      );
      expect(text('立即支付'), findsNothing);
      expect(t.takeException(), isNull);
    },
  );

  _paymentTest(
    'payment layout switches across 839/840 while preserving loaded order',
    (t, h) async {
      h.service.onRead = (_) async =>
          XbResult.success(order(XbOrderStatus.processing));
      await h.mount(t, size: const Size(839, 900));
      for (final width in [839.0, 840.0, 839.0]) {
        t.view.physicalSize = Size(width, 900);
        await t.pump();
        final check = t.getRect(text('检查支付状态'));
        final information = t.getRect(text('订单信息'));
        if (width < 840) {
          expect(check.top, greaterThan(information.bottom));
        } else {
          expect(check.left, greaterThan(information.right));
          expect(check.top, lessThan(information.top));
        }
        expect(text('开通中'), findsOneWidget);
        expect(t.takeException(), isNull);
      }
      expect(h.service.reads, 1);
    },
  );

  _paymentTest('payment uses remaining panel width after a desktop sidebar', (
    t,
    h,
  ) async {
    h.service.onRead = (_) async =>
        XbResult.success(order(XbOrderStatus.processing));
    await h.mount(t, size: const Size(840, 900), panelWidth: 632);
    final check = t.getRect(text('检查支付状态'));
    final information = t.getRect(text('订单信息'));
    expect(
      check.top,
      greaterThan(information.bottom),
      reason: '840窗口扣除208侧栏后只剩632，应使用单列',
    );
    expect(t.takeException(), isNull);
    expect(h.service.reads, 1);
  });

  _paymentTest(
    'dark narrow opening and long order at large text scale do not overflow',
    (t, h) async {
      h.service.onRead = (trade) async => XbResult.success(
        order(
          XbOrderStatus.processing,
          tradeNo: trade,
          plan: '用于检查窄屏和放大字体的长套餐名称',
        ),
      );
      await h.mount(
        t,
        tradeNo: '1234567890123456789012345678',
        size: const Size(360, 800),
        brightness: Brightness.dark,
        textScale: 2,
      );
      await tap(t, '检查支付状态');
      await t.pump(const Duration(milliseconds: 250));
      expect(text('开通中'), findsNWidgets(2));
      expect(t.takeException(), isNull);
    },
  );

  _paymentTest(
    'QR close after polling completion does not trigger completion twice',
    (t, h) async {
      await h.mount(t);
      h.service.onCheckout = () async =>
          XbResult.success(const CheckoutQrCode('fixture-payment-qr'));
      await tap(t, '立即支付');
      await t.pump(const Duration(milliseconds: 350));
      expect(text('扫码支付'), findsOneWidget);
      expect(
        t.widget<QrCodeView>(find.byType(QrCodeView)).data,
        'fixture-payment-qr',
      );
      expect(t.takeException(), isNull);
      h.service.onRead = (_) async =>
          XbResult.success(order(XbOrderStatus.completed));
      await t.pump(const Duration(seconds: 5));
      expect(h.subscription.calls, 1);
      await tap(t, '关闭');
      await t.pump(const Duration(milliseconds: 350));
      expect(text('已完成'), findsOneWidget);
      expect(h.subscription.calls, 1);
    },
  );
}
