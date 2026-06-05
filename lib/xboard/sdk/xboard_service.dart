/// 客户端反腐层抽象接口（conventions §2.1 / DD-3）。
///
/// **What**：UI / Provider 唯一依赖的 Xboard 操作面，屏蔽 SDK 类型与双返回形态。
/// **Why**：SDK 重构 / 换实现 / 加加密层都不动 UI 一行（conventions §2.1）。
/// **How**：实现类 `xboard_service_impl.dart` 是全工程唯一 import SDK barrel 的文件（F410）。
///
/// **18 个领域方法**（概念区分：SDK 是 11 个 adapter getter，本接口在其上聚合 18 个领域方法）：
/// 5 认证 + 3 账号订阅 + 7 套餐订单 + 1 支付 + 2 IpMirror。全部返 `Future<XbResult<T>>`
/// （DD-3 双形态归一），唯一例外 `fireAllMirrors` 返 void（fire-and-forget，Property 1 例外）。
library;

import '../models/checkout_outcome_ui.dart';
import '../models/order_summary.dart';
import '../models/plan_item.dart';
import '../models/xb_domain_subscription.dart';
import '../models/xb_domain_types.dart';
import '../models/xb_result.dart';

/// 反腐层抽象：UI / providers 与 SDK 之间的唯一桥梁。
abstract interface class XboardService {
  // ───────── 认证（R1/R2/R3/R4，5 方法）─────────

  /// 登录 → 返鉴权 token（F406：auth_data 优先）。
  Future<XbResult<String>> login(String email, String password);

  /// 注册 → 返是否成功（SDK register 不返 token，DD-9 后续二步 login）。
  Future<XbResult<bool>> register(
    String email,
    String password, {
    String? emailCode,
    String? inviteCode,
  });

  /// 发送邮箱验证码。
  Future<XbResult<bool>> sendEmailVerifyCode(String email);

  /// 忘记密码（验证码 + 新密码重置）。
  Future<XbResult<bool>> forgotPassword(
    String email,
    String code,
    String newPassword,
  );

  /// 退出登录（清服务端 + 本地 token）。
  Future<XbResult<void>> logout();

  // ───────── 站点配置（form-a R5.6，1 方法）─────────

  /// 邮箱注册白名单后缀（form-a 注册/忘记密码 sheet 用，R5.6 / 决策 10）。
  ///
  /// 内部调 SDK `ConfigApi.getConfig().emailWhitelistSuffix`。**仅 v2.0（formA）启用**：
  /// 形态 B 的 F240「v0.1 SHALL NOT 调 getConfig」约束在 v2.0 已解除（站点配置仍优先走
  /// Bootstrap JSON，本入口仅为 form-a 注册流程取白名单后缀）。
  /// 返回空列表 = 白名单禁用（任意后缀可注册，F208 语义）。
  Future<XbResult<List<String>>> getEmailSuffixes();

  // ───────── 账号 / 订阅（R6/R7，3 方法）─────────

  /// 拉账号订阅信息（/getSubscribe 单端点，D27）。
  Future<XbResult<XbDomainSubscription>> getSubscription();

  /// 拉完整订阅 URL（含订阅 token，F406）。
  Future<XbResult<String>> getSubscribeUrl();

  /// IpAuth 兜底登录态检查（R7.4，_skip_retry + 5s）。
  Future<XbResult<XbCheckLogin>> checkLogin();

  // ───────── 套餐 / 订单 / 支付（R8/R9，7 方法）─────────

  /// 套餐列表。
  Future<XbResult<List<PlanItem>>> getPlans();

  /// 创建订单 → 返 tradeNo（反腐层把 XbPlanPeriod→String 传 SDK）。
  Future<XbResult<String>> createOrder(
    int planId,
    XbPlanPeriod period, {
    String? couponCode,
  });

  /// 结算 → 返 5 分支结果（内部调 SDK checkoutOrder；零金额 method=''）。
  Future<XbResult<CheckoutOutcomeUi>> checkout(String tradeNo, String method);

  /// 订单列表（SDK PaginatedList.data → items，第 12 轮）。
  Future<XbResult<XbPagedList<OrderSummary>>> getOrders({
    int page = 1,
    int pageSize = 20,
  });

  /// 订单详情。
  Future<XbResult<OrderDetail?>> getOrder(String tradeNo);

  /// 取消订单。
  Future<XbResult<bool>> cancelOrder(String tradeNo);

  /// 校验优惠券（必传 period，F360）。
  Future<XbResult<CouponInfo?>> checkCoupon(
    String code,
    int planId,
    XbPlanPeriod period,
  );

  /// 支付方式列表（SDK payment.getPaymentMethods 无参，含 handlingFee*）。
  Future<XbResult<List<PaymentMethodItem>>> getPaymentMethods();

  // ───────── IpMirror 异步预热（R7.13.bis / F386，2 方法）─────────

  /// 拉镜像配置。
  Future<XbResult<IpMirrorConfigUi>> fetchMirrorList();

  /// 多出口预热 fire-and-forget（不返结果，Property 1 例外）。
  void fireAllMirrors(List<String> urls);
}
