/// 集成测试用 fake 反腐层（覆盖全 18 方法返回可控成功数据，无网络）。
///
/// 与 preview 的 fake 区别：套餐/订单/支付/优惠券/IpMirror 也返真实样例数据，
/// 支撑 W7 端到端流程（套餐→下单→结算→订单）。低延迟（10ms）便于集成测试快跑。
library;

import 'package:fl_clash/xboard/models/checkout_outcome_ui.dart';
import 'package:fl_clash/xboard/models/order_summary.dart';
import 'package:fl_clash/xboard/models/plan_item.dart';
import 'package:fl_clash/xboard/models/xb_domain_error.dart';
import 'package:fl_clash/xboard/models/xb_domain_subscription.dart';
import 'package:fl_clash/xboard/models/xb_domain_types.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/sdk/xboard_service.dart';

class FakeIntegrationService implements XboardService {
  FakeIntegrationService({this.loginShouldFail = false});

  bool loginShouldFail;
  int logoutCalls = 0;
  int createOrderCalls = 0;
  int checkoutCalls = 0;
  final List<String> firedMirrors = [];

  static const _d = Duration(milliseconds: 10);
  Future<void> get _delay => Future<void>.delayed(_d);

  @override
  Future<XbResult<String>> login(String email, String password) async {
    await _delay;
    if (loginShouldFail) {
      return XbResult.failure(XbDomainError.unauthorized('邮箱或密码错误'));
    }
    return XbResult.success('Bearer integ_token');
  }

  @override
  Future<XbResult<bool>> register(String email, String password,
      {String? emailCode, String? inviteCode}) async {
    await _delay;
    return XbResult.success(true);
  }

  @override
  Future<XbResult<bool>> sendEmailVerifyCode(String email) async {
    await _delay;
    return XbResult.success(true);
  }

  @override
  Future<XbResult<bool>> forgotPassword(
      String email, String code, String newPassword) async {
    await _delay;
    return XbResult.success(true);
  }

  @override
  Future<XbResult<void>> logout() async {
    await _delay;
    logoutCalls++;
    return XbResult.success(null);
  }

  @override
  Future<XbResult<XbDomainSubscription>> getSubscription() async {
    await _delay;
    return XbResult.success(XbDomainSubscription(
      email: 'demo@example.com',
      uuid: 'a1b2c3d4-int',
      planName: '专业版套餐',
      totalBytes: 100 * 1024 * 1024 * 1024,
      usedBytes: 37 * 1024 * 1024 * 1024,
      expiredAt: DateTime.now().add(const Duration(days: 23)),
      nextResetAt: DateTime.now().add(const Duration(days: 8)),
      planId: 1,
    ));
  }

  @override
  Future<XbResult<String>> getSubscribeUrl() async {
    await _delay;
    return XbResult.success('https://sub.example.com/s/integ_token');
  }

  @override
  Future<XbResult<XbCheckLogin>> checkLogin() async {
    await _delay;
    return XbResult.success(const XbCheckLogin(isLogin: true));
  }

  @override
  Future<XbResult<List<PlanItem>>> getPlans() async {
    await _delay;
    return XbResult.success(const [
      PlanItem(
        id: 1,
        name: '专业版',
        description: '100GB / 月',
        transferEnableGb: 100,
        prices: [
          PricePlan(period: XbPlanPeriod.monthly, amountYuan: 10),
          PricePlan(period: XbPlanPeriod.yearly, amountYuan: 100),
        ],
      ),
    ]);
  }

  @override
  Future<XbResult<String>> createOrder(int planId, XbPlanPeriod period,
      {String? couponCode}) async {
    await _delay;
    createOrderCalls++;
    return XbResult.success('TRADE_INT_$createOrderCalls');
  }

  @override
  Future<XbResult<CheckoutOutcomeUi>> checkout(String tradeNo, String method) async {
    await _delay;
    checkoutCalls++;
    return XbResult.success(const CheckoutPaid());
  }

  @override
  Future<XbResult<XbPagedList<OrderSummary>>> getOrders(
      {int page = 1, int pageSize = 20}) async {
    await _delay;
    return XbResult.success(XbPagedList(
      items: [
        OrderSummary(
          tradeNo: 'TRADE_OLD',
          planName: '专业版',
          period: XbPlanPeriod.monthly,
          totalAmountYuan: 10,
          status: XbOrderStatus.completed,
          createdAt: DateTime(2026, 1, 1),
        ),
      ],
      page: page,
      pageSize: pageSize,
      total: 1,
    ));
  }

  @override
  Future<XbResult<OrderDetail?>> getOrder(String tradeNo) async {
    await _delay;
    return XbResult.success(OrderDetail(
      summary: OrderSummary(
        tradeNo: tradeNo,
        planName: '专业版',
        period: XbPlanPeriod.monthly,
        totalAmountYuan: 10,
        status: XbOrderStatus.completed,
        createdAt: DateTime(2026, 1, 1),
      ),
    ));
  }

  @override
  Future<XbResult<bool>> cancelOrder(String tradeNo) async {
    await _delay;
    return XbResult.success(true);
  }

  @override
  Future<XbResult<CouponInfo?>> checkCoupon(
      String code, int planId, XbPlanPeriod period) async {
    await _delay;
    return XbResult.success(CouponInfo(code: code, type: 2, value: 10));
  }

  @override
  Future<XbResult<List<PaymentMethodItem>>> getPaymentMethods() async {
    await _delay;
    return XbResult.success(const [
      PaymentMethodItem(id: 'pm1', name: '支付宝', feeFixedYuan: 0, feePercent: 0),
    ]);
  }

  @override
  Future<XbResult<IpMirrorConfigUi>> fetchMirrorList() async {
    await _delay;
    return XbResult.success(const IpMirrorConfigUi(
      enabled: true,
      urls: ['https://m1.example.com', 'https://m2.example.com'],
      throttle: Duration(minutes: 5),
      fetchTimeout: Duration(seconds: 3),
    ));
  }

  @override
  void fireAllMirrors(List<String> urls) {
    firedMirrors.addAll(urls);
  }
}
