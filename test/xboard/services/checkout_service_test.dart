/// W7.5/7.7/7.8 — retryableCheckout 复用 pending + 订单状态机 + processing 超时（θ-7）。

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:fl_clash/xboard/models/checkout_outcome_ui.dart';
import 'package:fl_clash/xboard/models/xb_domain_error.dart';
import 'package:fl_clash/xboard/models/order_summary.dart';
import 'package:fl_clash/xboard/models/xb_domain_types.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/sdk/xboard_service.dart';
import 'package:fl_clash/xboard/services/checkout_service.dart';

class _MockService extends Mock implements XboardService {}

void main() {
  late _MockService service;
  late CheckoutService sut;

  setUpAll(() => registerFallbackValue(XbPlanPeriod.monthly));
  setUp(() {
    service = _MockService();
    sut = CheckoutService(service: service);
  });

  OrderSummary order(String tradeNo, XbOrderStatus status) => OrderSummary(
        tradeNo: tradeNo,
        period: XbPlanPeriod.monthly,
        totalAmountYuan: 10,
        status: status,
        createdAt: DateTime(2026, 1, 1),
      );

  group('retryableCheckout（§ H 复用 pending）', () {
    test('有 pending → 复用旧 tradeNo，不 createOrder', () async {
      when(() => service.getOrders(page: 1, pageSize: 5, forceRefresh: true)).thenAnswer((_) async =>
          XbResult.success(XbPagedList(
            items: [order('OLD', XbOrderStatus.pending)],
            page: 1, pageSize: 5, total: 1,
          )));
      when(() => service.checkout('OLD', any()))
          .thenAnswer((_) async => XbResult.success(const CheckoutPaid()));

      final r = await sut.retryableCheckout(
          planId: 7, period: XbPlanPeriod.monthly, method: 'alipay');
      expect((r as XbSuccess).data, isA<CheckoutPaid>());
      verify(() => service.checkout('OLD', 'alipay')).called(1);
      verifyNever(() => service.createOrder(any(), any(),
          couponCode: any(named: 'couponCode'))); // 不重新下单
    });

    test('无 pending → createOrder + checkout 新 tradeNo', () async {
      when(() => service.getOrders(page: 1, pageSize: 5, forceRefresh: true)).thenAnswer((_) async =>
          XbResult.success(const XbPagedList(items: <OrderSummary>[],
              page: 1, pageSize: 5, total: 0)));
      when(() => service.createOrder(any(), any(),
          couponCode: any(named: 'couponCode'))).thenAnswer((_) async => XbResult.success('NEW'));
      when(() => service.checkout('NEW', any()))
          .thenAnswer((_) async => XbResult.success(const CheckoutRedirect('https://pay')));

      final r = await sut.retryableCheckout(
          planId: 7, period: XbPlanPeriod.monthly, method: 'epay');
      expect((r as XbSuccess).data, isA<CheckoutRedirect>());
      verify(() => service.createOrder(7, XbPlanPeriod.monthly, couponCode: null)).called(1);
      verify(() => service.checkout('NEW', 'epay')).called(1);
    });

    test('createOrder 失败 → 透传 failure（不 checkout）', () async {
      when(() => service.getOrders(page: 1, pageSize: 5, forceRefresh: true)).thenAnswer((_) async =>
          XbResult.success(const XbPagedList(items: <OrderSummary>[],
              page: 1, pageSize: 5, total: 0)));
      when(() => service.createOrder(any(), any(),
              couponCode: any(named: 'couponCode')))
          .thenAnswer((_) async => XbResult.failure(XbDomainError.network(
              XbNetworkKind.timeout, 't')));
      final r = await sut.retryableCheckout(
          planId: 7, period: XbPlanPeriod.monthly, method: 'epay');
      expect(r, isA<XbFailure>());
      verifyNever(() => service.checkout(any(), any()));
    });
  });

  group('订单状态机（§ I）', () {
    test('shouldPoll：仅 pending/processing', () {
      expect(sut.shouldPoll(XbOrderStatus.pending), isTrue);
      expect(sut.shouldPoll(XbOrderStatus.processing), isTrue);
      expect(sut.shouldPoll(XbOrderStatus.completed), isFalse);
      expect(sut.shouldPoll(XbOrderStatus.cancelled), isFalse);
      expect(sut.shouldPoll(XbOrderStatus.discounted), isFalse);
    });

    test('isTerminal：cancelled/completed/discounted', () {
      expect(sut.isTerminal(XbOrderStatus.cancelled), isTrue);
      expect(sut.isTerminal(XbOrderStatus.completed), isTrue);
      expect(sut.isTerminal(XbOrderStatus.discounted), isTrue);
      expect(sut.isTerminal(XbOrderStatus.pending), isFalse);
    });

    test('shouldTriggerSync：completed/discounted → T3', () {
      expect(sut.shouldTriggerSync(XbOrderStatus.completed), isTrue);
      expect(sut.shouldTriggerSync(XbOrderStatus.discounted), isTrue);
      expect(sut.shouldTriggerSync(XbOrderStatus.cancelled), isFalse);
    });
  });

  group('processing 5min 超时（θ-7 单调时钟）', () {
    test('未记录 → 不超时', () {
      expect(sut.isProcessingTimedOut('T'), isFalse);
    });

    test('刚进入 processing → 不超时', () {
      sut.markProcessing('T');
      expect(sut.isProcessingTimedOut('T'), isFalse);
    });

    test('markProcessing 幂等（重复调用不重置计时）', () {
      sut.markProcessing('T');
      sut.markProcessing('T'); // 不重置
      expect(sut.isProcessingTimedOut('T'), isFalse);
    });

    test('clearProcessing → 计时清除', () {
      sut.markProcessing('T');
      sut.clearProcessing('T');
      expect(sut.isProcessingTimedOut('T'), isFalse);
    });
  });
}
