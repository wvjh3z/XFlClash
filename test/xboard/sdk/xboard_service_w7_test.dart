/// W7.2/7.3/7.6/7.9 — 套餐/订单/支付/优惠券反腐层映射 + CheckoutOutcome 5 分支 + XbPlanPeriod 转换。

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fl_clash/xboard/models/checkout_outcome_ui.dart' as ui;
import 'package:fl_clash/xboard/models/xb_domain_types.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/sdk/xboard_service_impl.dart';

import '../../_fixtures/fake_xboard_sdk.dart';

void main() {
  late FakeXBoardSDK sdk;
  late FakeSubApis apis;
  late XboardServiceImpl service;

  setUpAll(() {
    registerFallbackValue(PlanPeriod.monthly);
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    sdk = FakeXBoardSDK();
    apis = sdk.setupFor(XbScenario.loggedIn);
    service = XboardServiceImpl(sdk: sdk);
  });

  group('getPlans 映射（transferEnableGb 单位 + 价格列表）', () {
    test('PlanModel → PlanItem（transfer_enable 单位 GB + 仅 >0 价格入列）', () async {
      when(() => apis.planApi.getPlans()).thenAnswer((_) async => [
            const PlanModel(
              id: 7,
              groupId: 1,
              name: 'Pro',
              show: true,
              renew: true,
              transferEnable: 100, // GB（非 bytes）
              monthPrice: 10.0,
              yearPrice: 100.0,
              quarterPrice: 0, // 0 不入列
            ),
          ]);
      final r = await service.getPlans();
      final plan = (r as XbSuccess).data.single;
      expect(plan.id, 7);
      expect(plan.transferEnableGb, 100);
      // 仅 month + year（quarter=0 跳过）。
      expect(plan.prices.map((p) => p.period),
          containsAll([XbPlanPeriod.monthly, XbPlanPeriod.yearly]));
      expect(plan.prices.any((p) => p.period == XbPlanPeriod.quarterly), isFalse);
    });
  });

  group('createOrder（XbPlanPeriod → SDK PlanPeriod.value 旧版命名）', () {
    test('monthly → month_price 传给 SDK + 返 tradeNo', () async {
      when(() => apis.orderApi.createOrder(any(), any(),
          couponCode: any(named: 'couponCode'))).thenAnswer((_) async => 'TRADE123');
      final r = await service.createOrder(7, XbPlanPeriod.monthly);
      expect((r as XbSuccess).data, 'TRADE123');
      verify(() => apis.orderApi.createOrder(7, 'month_price',
          couponCode: null)).called(1);
    });

    test('yearly → year_price', () async {
      when(() => apis.orderApi.createOrder(any(), any(),
          couponCode: any(named: 'couponCode'))).thenAnswer((_) async => 'T2');
      await service.createOrder(1, XbPlanPeriod.yearly, couponCode: 'SAVE');
      verify(() => apis.orderApi.createOrder(1, 'year_price', couponCode: 'SAVE'))
          .called(1);
    });
  });

  group('checkout CheckoutOutcome 5 分支映射（Property 2 零穿透）', () {
    Future<ui.CheckoutOutcomeUi> checkoutWith(CheckoutOutcome o) async {
      when(() => apis.orderApi.checkoutOrder(any(), any()))
          .thenAnswer((_) async => o);
      final r = await service.checkout('T', 'alipay');
      return (r as XbSuccess<ui.CheckoutOutcomeUi>).data;
    }

    test('Redirect → ui.CheckoutRedirect', () async {
      final r = await checkoutWith(const CheckoutRedirect(url: 'https://pay'));
      expect(r, isA<ui.CheckoutRedirect>());
      expect((r as ui.CheckoutRedirect).url, 'https://pay');
    });
    test('QrCode → ui.CheckoutQrCode', () async {
      final r = await checkoutWith(const CheckoutQrCode(qrCodeUrl: 'https://qr'));
      expect((r as ui.CheckoutQrCode).qrCodeUrl, 'https://qr');
    });
    test('Paid → ui.CheckoutPaid', () async {
      expect(await checkoutWith(const CheckoutPaid()), isA<ui.CheckoutPaid>());
    });
    test('Canceled → ui.CheckoutCanceled', () async {
      final r = await checkoutWith(const CheckoutCanceled(message: 'user'));
      expect((r as ui.CheckoutCanceled).message, 'user');
    });
    test('Failed → ui.CheckoutFailed', () async {
      final r = await checkoutWith(const CheckoutFailed(message: 'boom'));
      expect((r as ui.CheckoutFailed).message, 'boom');
    });
  });

  group('getOrders（PaginatedList.data → items + status 映射）', () {
    test('OrderModel → OrderSummary（totalAmountInYuan + status enum）', () async {
      when(() => apis.orderApi.getOrders(
              page: any(named: 'page'), pageSize: any(named: 'pageSize')))
          .thenAnswer((_) async => PaginatedList<OrderModel>(
                data: [
                  OrderModel(
                    tradeNo: 'T1',
                    totalAmount: 1990, // cents → 19.9 yuan
                    period: 'month_price',
                    status: 3, // completed
                    createdAt: DateTime(2026, 1, 1),
                  ),
                ],
                total: 1,
                page: 1,
                pageSize: 20,
              ));
      final r = await service.getOrders();
      final paged = (r as XbSuccess).data;
      expect(paged.items.single.tradeNo, 'T1');
      expect(paged.items.single.totalAmountYuan, 19.9);
      expect(paged.items.single.status, XbOrderStatus.completed);
      expect(paged.total, 1);
    });
  });

  group('getPaymentMethods（payment adapter 无参 + 手续费单位）', () {
    test('handlingFeeFixed cents/100 = feeFixedYuan', () async {
      when(() => apis.paymentApi.getPaymentMethods()).thenAnswer((_) async => [
            const PaymentMethodModel(
              id: 'pm1',
              name: 'Alipay',
              handlingFeeFixed: 100, // cents → 1.0 yuan
              handlingFeePercent: 0.5,
            ),
          ]);
      final r = await service.getPaymentMethods();
      final pm = (r as XbSuccess).data.single;
      expect(pm.id, 'pm1');
      expect(pm.feeFixedYuan, 1.0);
      expect(pm.feePercent, 0.5);
    });
  });

  group('checkCoupon（CouponModel int? 兜底）', () {
    test('type/value null → 兜底 0', () async {
      when(() => apis.orderApi.checkCoupon(any(), any(), any()))
          .thenAnswer((_) async => const CouponModel(code: 'C'));
      final r = await service.checkCoupon('C', 7, XbPlanPeriod.monthly);
      final coupon = (r as XbSuccess).data!;
      expect(coupon.type, 0);
      expect(coupon.value, 0);
    });

    test('checkCoupon 传 SDK PlanPeriod（非 String）', () async {
      when(() => apis.orderApi.checkCoupon(any(), any(), any()))
          .thenAnswer((_) async => const CouponModel(code: 'C', type: 1, value: 10));
      await service.checkCoupon('C', 7, XbPlanPeriod.yearly);
      verify(() => apis.orderApi.checkCoupon('C', 7, PlanPeriod.yearly)).called(1);
    });
  });

  group('cancelOrder / getOrder', () {
    test('cancelOrder → bool', () async {
      when(() => apis.orderApi.cancelOrder(any())).thenAnswer((_) async => true);
      expect(((await service.cancelOrder('T')) as XbSuccess).data, isTrue);
    });
    test('getOrder null → XbSuccess(null)', () async {
      when(() => apis.orderApi.getOrder(any())).thenAnswer((_) async => null);
      expect(((await service.getOrder('T')) as XbSuccess).data, isNull);
    });
  });

  group('fetchMirrorList / fireAllMirrors', () {
    test('fetchMirrorList → IpMirrorConfigUi', () async {
      when(() => apis.ipMirrorApi.fetchMirrorList()).thenAnswer((_) async =>
          IpMirrorConfig(
            enabled: true,
            urls: const ['https://m1'],
            throttle: const Duration(minutes: 5),
            fetchTimeout: const Duration(seconds: 3),
          ));
      final r = await service.fetchMirrorList();
      expect((r as XbSuccess).data.urls, ['https://m1']);
    });

    test('fireAllMirrors void 不抛（SDK 抛也吞）', () {
      when(() => apis.ipMirrorApi.fireAllMirrors(any(),
          timeoutPerUrl: any(named: 'timeoutPerUrl'))).thenThrow(Exception('x'));
      expect(() => service.fireAllMirrors(['https://m1']), returnsNormally);
    });
  });
}
