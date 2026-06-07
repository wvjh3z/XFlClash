/// 失败重试审计（全异步操作点）—— 模拟 + 日志验证反腐层域名故障转移对每个 API 方法生效。
///
/// **目的**：「全异步操作点审计(15 处)」表里「域名故障转移=反腐层」这一列是断言，本测试把它
/// **逐方法跑实**。所有 API 方法都经 `_guard`/`_guardSdkResult`，故行为一致：
///   - 首次抛 `NetworkException`（当前域名挂）→ 触发一次 failOver 钩子 → 重试一次。
///   - 鉴权/业务错误 → **不** failOver（换域名也救不了）。
///
/// **model-free 技巧**：不构造各方法的 SDK 成功模型（构造器复杂易错）。而是让
///   - 第 1 次调用抛 `NetworkException` → 触发 failover；
///   - 第 2 次（重试）抛**不同的** `AuthException` → 结果带 XbUnauthorized。
/// 于是「结果是 XbUnauthorized + body 执行 2 次 + failover 1 次」即证明：failover 触发且确实重试了。
///
/// 每个 case 打印 `[XB-FAILOVER-AUDIT]` 日志；跑 `flutter test ... -r expanded` 可逐行核对。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fl_clash/xboard/models/xb_domain_error.dart';
import 'package:fl_clash/xboard/models/xb_domain_types.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/sdk/xboard_service_impl.dart';

import '../../_fixtures/fake_xboard_sdk.dart';

void log(String m) {
  // ignore: avoid_print
  print('[XB-FAILOVER-AUDIT] $m');
}

void main() {
  setUpAll(() {
    // checkCoupon 第 3 参是 SDK PlanPeriod（复杂类型），mocktail any() 需先注册 fallback。
    registerFallbackValue(PlanPeriod.monthly);
  });

  late FakeXBoardSDK sdk;
  late FakeSubApis apis;
  late int failoverCalls;
  late XboardServiceImpl service;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    sdk = FakeXBoardSDK();
    apis = sdk.setupFor(XbScenario.loggedIn);
    failoverCalls = 0;
    service = XboardServiceImpl(
      sdk: sdk,
      apiFailover: () async {
        failoverCalls++;
        log('  → failOverApi() 触发：探测候选域名并热替换 baseUrl');
      },
    );
  });

  /// 审计「可重试」：首次网络失败 → failover → 重试（重试抛 Auth 以免依赖成功模型）。
  /// 证明点：failover 1 次 + body 执行 2 次 + 结果是重试那次的错误（XbUnauthorized）。
  Future<void> auditRetryable(
    String name,
    void Function(Object first, Object second) stub2,
    Future<XbResult<Object?>> Function() invoke,
  ) async {
    log('▶ $name：首次网络失败 → 期望 failover 1 次 + 重试');
    stub2(NetworkException('domain down'), AuthException('retry hit'));
    final r = await invoke();
    log('  结果=${r.runtimeType}，failoverCalls=$failoverCalls');
    expect(failoverCalls, 1, reason: '$name failover 恰好一次');
    expect((r as XbFailure).error, isA<XbUnauthorized>(),
        reason: '$name 结果应是「重试那次」的错误（证明确实重试了）');
  }

  group('可重试 API（网络错误 → failover + 重试）', () {
    test('#5 getSubscription（账号卡）', () async {
      var n = 0;
      await auditRetryable('getSubscription', (a, b) {
        when(() => apis.subscriptionApi.getSubscription())
            .thenAnswer((_) async => throw (++n == 1 ? a : b));
      }, () => service.getSubscription());
      expect(n, 2);
    });

    test('#6 getPlans（套餐列表/续费/重置）', () async {
      var n = 0;
      await auditRetryable('getPlans', (a, b) {
        when(() => apis.planApi.getPlans())
            .thenAnswer((_) async => throw (++n == 1 ? a : b));
      }, () => service.getPlans());
      expect(n, 2);
    });

    test('#8/#14 createOrder（提交订单/流量重置）', () async {
      var n = 0;
      await auditRetryable('createOrder', (a, b) {
        when(() => apis.orderApi.createOrder(any(), any(),
                couponCode: any(named: 'couponCode')))
            .thenAnswer((_) async => throw (++n == 1 ? a : b));
      }, () => service.createOrder(1, XbPlanPeriod.monthly));
      expect(n, 2);
    });

    test('#12 checkout（立即支付）', () async {
      var n = 0;
      await auditRetryable('checkout', (a, b) {
        when(() => apis.orderApi.checkoutOrder(any(), any()))
            .thenAnswer((_) async => throw (++n == 1 ? a : b));
      }, () => service.checkout('TRADE', 'alipay'));
      expect(n, 2);
    });

    test('#9 getOrders（订单列表/待支付横幅）', () async {
      var n = 0;
      await auditRetryable('getOrders', (a, b) {
        when(() => apis.orderApi.getOrders(
                page: any(named: 'page'),
                pageSize: any(named: 'pageSize'),
                forceRefresh: any(named: 'forceRefresh')))
            .thenAnswer((_) async => throw (++n == 1 ? a : b));
      }, () => service.getOrders());
      expect(n, 2);
    });

    test('#10 getOrder（订单支付加载）', () async {
      var n = 0;
      await auditRetryable('getOrder', (a, b) {
        when(() => apis.orderApi.getOrder(any()))
            .thenAnswer((_) async => throw (++n == 1 ? a : b));
      }, () => service.getOrder('T'));
      expect(n, 2);
    });

    test('#13 cancelOrder（取消订单）', () async {
      var n = 0;
      await auditRetryable('cancelOrder', (a, b) {
        when(() => apis.orderApi.cancelOrder(any()))
            .thenAnswer((_) async => throw (++n == 1 ? a : b));
      }, () => service.cancelOrder('T'));
      expect(n, 2);
    });

    test('#11 getPaymentMethods（支付方式）', () async {
      var n = 0;
      await auditRetryable('getPaymentMethods', (a, b) {
        when(() => apis.paymentApi.getPaymentMethods())
            .thenAnswer((_) async => throw (++n == 1 ? a : b));
      }, () => service.getPaymentMethods());
      expect(n, 2);
    });

    test('#7 checkCoupon（优惠码）', () async {
      var n = 0;
      await auditRetryable('checkCoupon', (a, b) {
        when(() => apis.orderApi.checkCoupon(any(), any(), any()))
            .thenAnswer((_) async => throw (++n == 1 ? a : b));
      }, () => service.checkCoupon('X', 1, XbPlanPeriod.monthly));
      expect(n, 2);
    });

    test('#1 login（SdkResult 形态：Failure(NetworkError) 真实网络失败路径）', () async {
      log('▶ login：首次 Failure(NetworkError) → 期望 failover 1 次 + 重试');
      var n = 0;
      // SdkResult 形态：真实网络失败是 Failure(NetworkError)（非 throw）→ _mapError → XbNetwork → failover。
      when(() => apis.authApi.loginResult(any(), any())).thenAnswer((_) async {
        if (++n == 1) {
          return const Failure(NetworkError('domain down', kind: NetworkErrorKind.timeout));
        }
        return const Failure(UnauthorizedError('retry hit'));
      });
      final r = await service.login('a@b.com', 'pw');
      log('  结果=${r.runtimeType}，failoverCalls=$failoverCalls，body 执行=$n 次');
      expect(failoverCalls, 1, reason: 'login 网络失败应 failover 一次');
      expect((r as XbFailure).error, isA<XbUnauthorized>(),
          reason: '结果是重试那次的错误（证明重试了）');
      expect(n, 2);
    });
  });

  group('不可重试错误（鉴权/业务 → 不 failover）', () {
    test('#5 getSubscription 鉴权失效 → 0 次 failover', () async {
      log('▶ getSubscription 鉴权失效：期望 0 次 failover');
      var n = 0;
      when(() => apis.subscriptionApi.getSubscription()).thenAnswer((_) async {
        n++;
        throw AuthException('登录已过期');
      });
      final r = await service.getSubscription();
      log('  结果=${r.runtimeType}，failoverCalls=$failoverCalls，body 执行=$n 次');
      expect((r as XbFailure).error, isA<XbUnauthorized>());
      expect(failoverCalls, 0, reason: '鉴权错误换域名无用');
      expect(n, 1, reason: 'body 只执行一次');
    });

    test('#8 createOrder 业务错误（如余额不足）→ 0 次 failover', () async {
      log('▶ createOrder 业务错误：期望 0 次 failover');
      var n = 0;
      when(() => apis.orderApi.createOrder(any(), any(),
              couponCode: any(named: 'couponCode')))
          .thenAnswer((_) async {
        n++;
        throw ApiException('余额不足');
      });
      final r = await service.createOrder(1, XbPlanPeriod.monthly);
      log('  结果=${r.runtimeType}，failoverCalls=$failoverCalls，body 执行=$n 次');
      expect(r, isA<XbFailure>());
      expect(failoverCalls, 0, reason: '业务错误换域名无用');
      expect(n, 1);
    });
  });

  group('无 failover 钩子（未注入）→ 原地失败不崩', () {
    test('getPlans 网络错误 → 单次失败、不重试', () async {
      log('▶ 无钩子降级：期望原地返回失败、不崩');
      final svcNoHook = XboardServiceImpl(sdk: sdk); // 不传 apiFailover
      var n = 0;
      when(() => apis.planApi.getPlans()).thenAnswer((_) async {
        n++;
        throw NetworkException('down');
      });
      final r = await svcNoHook.getPlans();
      log('  结果=${r.runtimeType}（应 XbFailure），body 执行=$n 次（应 1）');
      expect((r as XbFailure).error, isA<XbNetwork>());
      expect(n, 1);
    });
  });
}
