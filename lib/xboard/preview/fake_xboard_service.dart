/// 预览用 fake 反腐层（仅 `preview_main.dart` 用，不进 release 运行路径）。
///
/// 行为：认证方法（login/register/sendEmailVerifyCode/forgotPassword/logout）模拟网络延迟后
/// 返回 success，让预览能展示 loading→成功 全流程；其余领域方法返回 not_implemented 失败
/// （预览 gallery 只进认证页，不触达套餐/订单链路）。
///
/// **特殊邮箱触发错误态演示**（方便看错误 UI）：
/// - `rate@x.com` → 登录 rateLimit 倒计时
/// - `ban@x.com`  → 登录 banned
/// - `exist@x.com` → 注册 emailAlreadyExists
library;

import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart'
    show BusinessErrorKind, RateLimitKind;

import '../models/checkout_outcome_ui.dart';
import '../models/order_summary.dart';
import '../models/plan_item.dart';
import '../models/xb_domain_error.dart';
import '../models/xb_domain_subscription.dart';
import '../models/xb_domain_types.dart';
import '../models/xb_result.dart';
import '../sdk/xboard_service.dart';

class FakeXboardService implements XboardService {
  static const _latency = Duration(milliseconds: 900);

  Future<void> get _delay => Future<void>.delayed(_latency);

  static XbResult<T> _notImpl<T>(String op) =>
      XbResult.failure(XbDomainError.unexpected(op, 'preview_not_implemented'));

  // ───────── 认证 ─────────

  @override
  Future<XbResult<String>> login(String email, String password) async {
    await _delay;
    final e = email.toLowerCase().trim();
    if (e == 'rate@x.com') {
      return XbResult.failure(
          XbDomainError.rateLimit(RateLimitKind.login, 5, '密码错误次数过多'));
    }
    if (e == 'ban@x.com') {
      return XbResult.failure(
          XbDomainError.business(BusinessErrorKind.banned, '账号已被封禁', null));
    }
    if (password == 'wrong') {
      return XbResult.failure(XbDomainError.unauthorized('邮箱或密码错误'));
    }
    return XbResult.success('Bearer fake_preview_token');
  }

  @override
  Future<XbResult<bool>> register(
    String email,
    String password, {
    String? emailCode,
    String? inviteCode,
  }) async {
    await _delay;
    if (email.toLowerCase().trim() == 'exist@x.com') {
      return XbResult.failure(XbDomainError.business(
          BusinessErrorKind.emailAlreadyExists, '邮箱已被使用', null));
    }
    if (emailCode == '000000') {
      return XbResult.failure(XbDomainError.business(
          BusinessErrorKind.invalidEmailCode, '验证码错误', null));
    }
    return XbResult.success(true);
  }

  @override
  Future<XbResult<bool>> sendEmailVerifyCode(String email) async {
    await _delay;
    return XbResult.success(true);
  }

  @override
  Future<XbResult<bool>> forgotPassword(
    String email,
    String code,
    String newPassword,
  ) async {
    await _delay;
    if (code == '000000') {
      return XbResult.failure(XbDomainError.business(
          BusinessErrorKind.invalidEmailCode, '验证码错误或已过期', null));
    }
    return XbResult.success(true);
  }

  @override
  Future<XbResult<void>> logout() async {
    await _delay;
    return XbResult.success(null);
  }

  @override
  Future<XbResult<List<String>>> getEmailSuffixes() async {
    await _delay;
    // 预览样例白名单后缀（form-a 注册/忘记密码 sheet 下拉）。
    return XbResult.success(const ['gmail.com', 'qq.com', '163.com']);
  }

  // ───────── 账号 / 订阅（预览展示样例数据）─────────

  @override
  Future<XbResult<XbDomainSubscription>> getSubscription() async {
    await _delay;
    return XbResult.success(XbDomainSubscription(
      email: 'demo@example.com',
      uuid: 'a1b2c3d4-5678-90ab-cdef',
      planName: '专业版套餐',
      totalBytes: 100 * 1024 * 1024 * 1024, // 100 GB
      usedBytes: 37 * 1024 * 1024 * 1024, // 37 GB
      expiredAt: DateTime.now().add(const Duration(days: 23)),
      nextResetAt: DateTime.now().add(const Duration(days: 8, hours: 5)),
      planId: 1,
    ));
  }

  @override
  Future<XbResult<String>> getSubscribeUrl() async => _notImpl('getSubscribeUrl');

  @override
  Future<XbResult<XbCheckLogin>> checkLogin() async => _notImpl('checkLogin');

  // ───────── 套餐 / 订单 / 支付（预览不触达）─────────

  @override
  Future<XbResult<List<PlanItem>>> getPlans() async => _notImpl('getPlans');

  @override
  Future<XbResult<String>> createOrder(
    int planId,
    XbPlanPeriod period, {
    String? couponCode,
  }) async =>
      _notImpl('createOrder');

  @override
  Future<XbResult<CheckoutOutcomeUi>> checkout(
    String tradeNo,
    String method,
  ) async =>
      _notImpl('checkout');

  @override
  Future<XbResult<XbPagedList<OrderSummary>>> getOrders({
    int page = 1,
    int pageSize = 20,
  }) async =>
      _notImpl('getOrders');

  @override
  Future<XbResult<OrderDetail?>> getOrder(String tradeNo) async =>
      _notImpl('getOrder');

  @override
  Future<XbResult<bool>> cancelOrder(String tradeNo) async =>
      _notImpl('cancelOrder');

  @override
  Future<XbResult<CouponInfo?>> checkCoupon(
    String code,
    int planId,
    XbPlanPeriod period,
  ) async =>
      _notImpl('checkCoupon');

  @override
  Future<XbResult<List<PaymentMethodItem>>> getPaymentMethods() async =>
      _notImpl('getPaymentMethods');

  // ───────── IpMirror ─────────

  @override
  Future<XbResult<IpMirrorConfigUi>> fetchMirrorList() async =>
      _notImpl('fetchMirrorList');

  @override
  void fireAllMirrors(List<String> urls) {}
}
