/// W7.2/7.3/7.6/7.9 — 套餐/订单/支付/优惠券反腐层映射 + CheckoutOutcome 5 分支 + XbPlanPeriod 转换。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart';
import 'package:flutter_xboard_sdk/src/adapters/xboard/xboard_plan_adapter.dart';
import 'package:flutter_xboard_sdk/src/panels/xboard/apis/xboard_plan_api.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fl_clash/xboard/models/checkout_outcome_ui.dart' as ui;
import 'package:fl_clash/xboard/models/xb_domain_types.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/models/xb_domain_error.dart';
import 'package:fl_clash/xboard/sdk/xboard_service_impl.dart';

import '../../_fixtures/fake_xboard_sdk.dart';
import 'order_http_fixture.dart';

void main() {
  late FakeXBoardSDK sdk;
  late FakeSubApis apis;
  late OrderFixtureHttp http;
  late XboardServiceImpl service;

  setUpAll(() {
    registerFallbackValue(PlanPeriod.monthly);
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    sdk = FakeXBoardSDK();
    apis = sdk.setupFor(XbScenario.loggedIn);
    http = OrderFixtureHttp();
    when(() => sdk.httpService).thenReturn(http);
    when(() => http.getRequest(orderDetailPath('T')))
        .thenAnswer((_) async => orderWireDetail());
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

    test('panel and SDK preserve explicit zero only for reset prices', () async {
      final payloads = [
        <String, Object?>{},
        {'reset_price': null},
        {'reset_price': 0},
        {'reset_price': 800},
        {'reset_price': -1},
        {'reset_price': 'invalid'},
        {'reset_price': 'NaN'},
        {'reset_price': 'Infinity'},
        {'reset_price': 1.5},
      ];
      when(() => sdk.plan)
          .thenReturn(XBoardPlanAdapter(XBoardPlanApi(http)));
      when(() => http.getRequest('/api/v1/user/plan/fetch')).thenAnswer(
        (_) async => {
          'success': true,
          'data': [
            for (final (index, fields) in payloads.indexed)
              {
                'id': index + 1,
                'group_id': 1,
                'transfer_enable': 100,
                'name': 'fixture',
                'show': true,
                'renew': true,
                'month_price': 0,
                ...fields,
              },
          ],
        },
      );
      final r = await service.getPlans();
      final prices = r.dataOrNull!.map((plan) => plan.prices).toList();
      expect(prices.map((ps) => ps.singleOrNull?.amountYuan), [
        null, null, 0.0, 8.0, null, null, null, null, null,
      ]);
      expect(
        prices.expand((ps) => ps).map((p) => p.period),
        everyElement(XbPlanPeriod.resetTraffic),
      );
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
    test('Failed → unconfirmed after one read-only order check, never checkout twice', () async {
      when(() => apis.orderApi.checkoutOrder('T', 'alipay'))
          .thenAnswer((_) async => const CheckoutFailed(message: 'boom'));
      final r = await service.checkout('T', 'alipay');
      expect(r, isA<XbFailure<ui.CheckoutOutcomeUi>>());
      final error = (r as XbFailure<ui.CheckoutOutcomeUi>).error;
      expect(error, isA<XbUnconfirmed>());
      expect((error as XbUnconfirmed).operation, 'checkout');
      verify(() => apis.orderApi.checkoutOrder('T', 'alipay')).called(1);
      verify(() => http.getRequest(orderDetailPath('T'))).called(2);
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

    test('normalizes optional icons against the actual active API prefix', () async {
      var endpoint = 'https://brand-a.example.test:8443/panel/a';
      when(() => sdk.baseUrl).thenAnswer((_) => endpoint);
      when(() => apis.paymentApi.getPaymentMethods()).thenAnswer((_) async => [
        for (final raw in [
          'images/payment.svg?v=2',
          '/icons/card.png',
          '/panel/a/icons/card.png',
          'https://art.example.test/card.webp',
          'http://art.example.test/card.png',
          '//art.example.test/card.webp',
          'https://user:secret@art.example.test/card.png',
          'https://@art.example.test/card.png',
          'https://art.example.test:0/card.png',
          'file:///private/icon.png',
          'data:image/svg+xml,invalid',
          'icons\\card.png',
          '../outside.png',
          '%2e%2e/outside.png',
          'a%2f..%2f..%2foutside.png',
          '',
        ])
          PaymentMethodModel(id: raw, name: 'Channel', icon: raw),
      ]);

      Future<List<String?>> icons() async =>
          (await service.getPaymentMethods()).dataOrNull!
              .map((item) => item.icon)
              .toList();
      expect(await icons(), [
        'https://brand-a.example.test:8443/panel/a/images/payment.svg?v=2',
        'https://brand-a.example.test:8443/panel/a/icons/card.png',
        'https://brand-a.example.test:8443/panel/a/icons/card.png',
        'https://art.example.test/card.webp',
        'http://art.example.test/card.png',
        ...List<String?>.filled(11, null),
      ]);
      endpoint = 'https://brand-b.example.test/alternate/';
      expect(
        (await icons()).first,
        'https://brand-b.example.test/alternate/images/payment.svg?v=2',
      );
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
      verifyInOrder([
        () => http.getRequest(orderDetailPath('T')),
        () => apis.orderApi.cancelOrder('T'),
      ]);
    });
    test('getOrder with null detail fails closed', () async {
      when(() => http.getRequest(orderDetailPath('T')))
          .thenAnswer((_) async => {'success': true, 'data': null});
      expect((await service.getOrder('T')).errorOrNull, isA<XbServer>());
      verify(() => http.getRequest(orderDetailPath('T'))).called(1);
    });
  });

  group('fetchMirrorList / fireAllMirrors', () {
    test('fetchMirrorList → IpMirrorConfigUi', () async {
      when(() => apis.ipMirrorApi.fetchMirrorList()).thenAnswer((_) async =>
          const IpMirrorConfig(
            enabled: true,
            urls: ['https://m1'],
            throttle: Duration(minutes: 5),
            fetchTimeout: Duration(seconds: 3),
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
