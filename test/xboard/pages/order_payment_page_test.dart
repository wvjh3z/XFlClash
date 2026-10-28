import 'package:fl_clash/ui/qr_code.dart';
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
import 'package:fl_clash/xboard/providers/user_profile_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/sdk/xboard_service.dart';
import 'package:fl_clash/xboard/services/xboard_subscription_service.dart';

OrderDetail order(
  XbOrderStatus status, {
  String tradeNo = 'T1',
  String plan = '标准套餐',
}) => OrderDetail(
  summary: OrderSummary(
    tradeNo: tradeNo,
    planName: plan,
    period: XbPlanPeriod.quarterly,
    totalAmountYuan: 40,
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
  final button = find
      .ancestor(
        of: text(label),
        matching: find.byWidgetPredicate(
          (widget) => widget is ButtonStyleButton,
        ),
      )
      .first;
  if (button.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      text(label),
      200,
      scrollable: find.byType(Scrollable).first,
    );
  }
  await tester.ensureVisible(button);
  await tester.pump();
  await tester.tap(button);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
}

Finder text(String label) => find.text(label, findRichText: true);

void main() {
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
        await tap(t, '检测支付状态');
        expect(text('待支付'), findsOneWidget);
        expect(text('检测失败'), findsOneWidget);
        expect(text('重新检测'), findsOneWidget);
        expect(h.subscription.calls, 0);
      },
    );
  }

  _paymentTest('discounted status refreshes once and stops polling', (
    t,
    h,
  ) async {
    await h.mount(t);
    h.service.onRead = (_) async =>
        XbResult.success(order(XbOrderStatus.discounted));
    await tap(t, '检测支付状态');
    expect(text('订单已折抵'), findsOneWidget);
    expect(h.subscription.calls, 1);
    await t.pump(const Duration(seconds: 12));
    expect(h.service.reads, 2);
    expect(h.subscription.calls, 1);
  });

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
    'manual detection shows busy, disables actions, and shares slow request',
    (t, h) async {
      await h.mount(t);
      final response = Completer<XbResult<OrderDetail?>>();
      h.service.onRead = (_) => response.future;
      await tap(t, '检测支付状态');
      expect(text('正在检测…'), findsOneWidget);
      for (final label in ['立即支付', '取消订单', '正在检测…']) {
        expect(
          t
              .widget<ButtonStyleButton>(
                find
                    .ancestor(
                      of: text(label),
                      matching: find.byWidgetPredicate(
                        (widget) => widget is ButtonStyleButton,
                      ),
                    )
                    .first,
              )
              .onPressed,
          isNull,
        );
      }
      await tap(t, '正在检测…');
      await t.pump(const Duration(seconds: 12));
      expect(h.service.reads, 2);
      response.complete(XbResult.success(order(XbOrderStatus.pending)));
      await t.pump();
      expect(text('订单仍待支付'), findsOneWidget);
      expect(text('若已完成付款，请稍后再试。'), findsOneWidget);
      expect(text('检测支付状态'), findsOneWidget);
      expect(h.subscription.calls, 0);
    },
  );

  _paymentTest(
    'manual query joins polling and completion refreshes exactly once',
    (t, h) async {
      await h.mount(t);
      final accountsBefore = h.service.subscriptionReads;
      final response = Completer<XbResult<OrderDetail?>>();
      h.service.onRead = (_) => response.future;
      await t.pump(const Duration(seconds: 5));
      expect(h.service.reads, 2);
      await tap(t, '检测支付状态');
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
    await tap(t, '检测支付状态');
    expect(text('检测失败'), findsOneWidget);
    expect(text('待支付'), findsOneWidget);
    expect(text('重新检测'), findsOneWidget);
    h.service.onRead = (_) async =>
        XbResult.success(order(XbOrderStatus.processing));
    await tap(t, '重新检测');
    expect(text('开通中'), findsNWidgets(2));
    expect(text('付款已确认，正在开通服务，请勿重复支付。'), findsNWidgets(2));
    expect(text('立即支付'), findsNothing);
    expect(find.widgetWithText(OutlinedButton, '取消订单'), findsNothing);
    expect(text('检测支付状态'), findsOneWidget);
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
    await tap(t, '检测支付状态');
    expect(text('开通中'), findsOneWidget);
    expect(text('检测失败'), findsOneWidget);
    h.service.onRead = (_) async =>
        XbResult.success(order(XbOrderStatus.pending));
    await tap(t, '重新检测');
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
      await tap(t, '检测支付状态');
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
      await t.pump(const Duration(seconds: 5));
      await tap(t, '立即支付');
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
    expect(text('标准套餐'), findsOneWidget);
    expect(text('立即支付'), findsOneWidget);
  });

  _paymentTest(
    'payment methods failure remains local and reload does not refetch order',
    (t, h) async {
      h.service.onMethods = () async =>
          XbResult.failure(const XbServer(503, 'unavailable'));
      await h.mount(t);
      expect(text('标准套餐'), findsOneWidget);
      expect(text('支付方式加载失败'), findsOneWidget);
      h.service.onMethods = null;
      await tap(t, '重新加载');
      await t.pump(const Duration(milliseconds: 350));
      expect(text('支付方式加载失败'), findsNothing);
      expect(text('支付宝'), findsOneWidget);
      expect(h.service.reads, 1);
    },
  );

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
    await tap(t, '检测支付状态');
    expect(text('正在检测…'), findsNothing);
    expect(text('重新检测'), findsOneWidget);
    expect(text('检测失败'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  _paymentTest(
    'asynchronous query rejection releases the shared request for retry',
    (t, h) async {
      await h.mount(t);
      final response = Completer<XbResult<OrderDetail?>>();
      h.service.onRead = (_) => response.future;
      await tap(t, '检测支付状态');
      response.completeError(StateError('controlled asynchronous failure'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 350));
      expect(text('重新检测'), findsOneWidget);
      expect(t.takeException(), isNull);
      final previous = h.service.reads;
      h.service.onRead = (_) async =>
          XbResult.success(order(XbOrderStatus.pending));
      await tap(t, '重新检测');
      expect(h.service.reads, previous + 1);
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
    await tap(t, '检测支付状态');
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
      await tap(t, '检测支付状态');
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
    await tap(t, '检测支付状态');
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
    await tap(t, '检测支付状态');
    await h.mount(t, tradeNo: 'T2');
    old.complete(
      XbResult.success(order(XbOrderStatus.completed, plan: '旧订单套餐')),
    );
    await t.pump();
    await t.pump(const Duration(milliseconds: 350));
    expect(text('新订单套餐'), findsOneWidget);
    expect(text('旧订单套餐'), findsNothing);
    expect(h.subscription.calls, 0);
    expect(h.service.trades, contains('T2'));
  });

  _paymentTest(
    'background pauses polling and resume silently queries latest status',
    (t, h) async {
      await h.mount(t);
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

  _paymentTest(
    'desktop opening keeps information and detection in two columns',
    (t, h) async {
      h.service.onRead = (_) async =>
          XbResult.success(order(XbOrderStatus.processing));
      await h.mount(t, size: const Size(1200, 800));
      expect(text('开通中'), findsOneWidget);
      expect(
        t.getTopLeft(text('产品信息')).dx,
        lessThan(t.getTopLeft(text('检测支付状态')).dx),
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
        final check = t.getRect(text('检测支付状态'));
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
    final check = t.getRect(text('检测支付状态'));
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
      await tap(t, '检测支付状态');
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
