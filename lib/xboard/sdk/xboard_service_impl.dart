/// 反腐层实现 —— **全工程唯一** `import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart'`
/// 的文件（conventions §2.1 / F410）。
///
/// **注入式构造（决策 #9）**：`XboardServiceImpl({required XBoardSDK sdk})` —— 生产端从
/// `xboardSdkProvider` 读 `XBoardSDK.instance`，测试端注入 fake（W0.3）。conventions §2.2
/// 「反腐层不接 SDK 单例」+ design 决策 #9「测试可替换性」双重约束。
///
/// **双形态归一（DD-3）**：SDK 部分方法返 `SdkResult`（switch 解构），部分 throw 旧异常
/// （try/catch 归一），统一吸收为 `XbResult<T>`。`_mapError` 是 SdkError → XbDomainError 唯一翻译入口。
///
/// **永不抛（Property 1 / NFR-7 / R11.5）**：17 个返结果方法在任何 SDK 形态下都返 XbResult，
/// 绝不向 UI 抛异常（含 SDK 内部 `fromJson` 的 TypeError，θ-11 broad catch）。`fireAllMirrors`
/// 是 void fire-and-forget 例外。
///
/// **θ-8 in-flight race 防御**：logout 期间置 `_isLoggingOut=true`，success 回调写 cache 前
/// 先查该 flag（W3.6 / W4.4 用 `_writeIfNotLoggingOut` 守卫）。
library;

import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart';

import '../models/checkout_outcome_ui.dart';
import '../models/order_summary.dart';
import '../models/plan_item.dart';
import '../models/xb_domain_error.dart';
import '../models/xb_domain_subscription.dart';
import '../models/xb_domain_types.dart';
import '../models/xb_result.dart';
import '../util/subscription_cache.dart';
import 'xboard_service.dart';

class XboardServiceImpl implements XboardService {
  XboardServiceImpl({required XBoardSDK sdk, SubscriptionCache? subscriptionCache})
      : _sdk = sdk,
        _subscriptionCache = subscriptionCache ?? SubscriptionCache();

  final XBoardSDK _sdk;

  /// R6 离线缓存（决策 #11 success-write，W4.4）。
  final SubscriptionCache _subscriptionCache;

  /// θ-8：logout 期间为 true，反腐层 success 回调写 cache 前先查（W3.6 填实清理链时置位）。
  // ignore: prefer_final_fields  (W3.6 logout 会写 true/false，非 final)
  bool _isLoggingOut = false;

  /// in-flight 写守卫（θ-8）：logout 期间丢弃 success 写入（design § B 末段）。
  Future<void> _writeIfNotLoggingOut(Future<void> Function() writeOp) async {
    if (_isLoggingOut) return;
    await writeOp();
  }

  // ───────── _mapError：SdkError sealed → XbDomainError（DD-3/D26/D67，唯一翻译入口）─────────
  //
  // 🟡 C37：XbBusiness 故意不持 SDK BusinessError.httpStatusCode（业务层不暴露 HTTP 细节）；
  // ServerError.httpStatusCode 仅给 XbServer（"服务端故障"语义，UI 不分 4xx/5xx 细分）。
  XbDomainError _mapError(SdkError e) => switch (e) {
        UnauthorizedError() => XbDomainError.unauthorized(e.message),
        RateLimitError(:final kind, :final retryAfterMinutes) =>
          XbDomainError.rateLimit(kind, retryAfterMinutes, e.message),
        BusinessError(:final kind, :final validationErrors) =>
          XbDomainError.business(kind, e.message, validationErrors),
        NetworkError(:final kind) => XbDomainError.network(kind, e.message),
        ServerError(:final httpStatusCode) =>
          XbDomainError.server(httpStatusCode, e.message),
        SecurityError() => XbDomainError.security(e.message),
        UnexpectedError(:final operation) =>
          XbDomainError.unexpected(operation, e.message),
      };

  /// throw 形态归一（design L797-833 + C37）：旧异常体系 3 子类 + catch-all 兜底。
  ///
  /// broad catch（θ-11）拦截 SDK 内部 `fromJson` 的 `TypeError` 等，走 XbUnexpected 不闪退。
  Future<XbResult<T>> _guard<T>(
    String operation,
    Future<T> Function() body,
  ) async {
    try {
      return XbResult.success(await body());
    } on AuthException catch (e) {
      return XbResult.failure(XbDomainError.unauthorized(e.message));
    } on NetworkException catch (e) {
      return XbResult.failure(
          XbDomainError.network(NetworkErrorKind.unknown, e.message));
    } on ApiException catch (e) {
      return XbResult.failure(
          XbDomainError.business(BusinessErrorKind.generic, e.message, null));
    } catch (e) {
      return XbResult.failure(XbDomainError.unexpected(operation, e.toString()));
    }
  }

  /// SdkResult 形态归一（switch 解构，Success/Failure 非 Ok/Err，F410）。
  XbResult<R> _fromSdkResult<S, R>(SdkResult<S> r, R Function(S data) map) =>
      switch (r) {
        Success(:final data) => XbResult.success(map(data)),
        Failure(:final error) => XbResult.failure(_mapError(error)),
      };

  // ───────── 18 方法 stub（逐 wave 填实；W2.2 先注入式骨架 + 双形态归一就位）─────────

  static XbResult<T> _notImpl<T>(String op) =>
      XbResult.failure(XbDomainError.unexpected(op, 'not_implemented'));

  @override
  Future<XbResult<String>> login(String email, String password) async {
    // SdkResult 形态（switch 解构）+ D69 email 预处理（trim + lowercase）。
    final r = await _sdk.auth.loginResult(email.toLowerCase().trim(), password);
    final result = _fromSdkResult(r, (token) => token); // data 已是鉴权 token（F406）
    // 🔴 W3.9（F406 致命语义）：SDK `auth.loginResult` **不自动存 token**（只有便捷方法
    // `loginWithCredentials` 才存）；反腐层必须显式 saveToken，否则后续 API 无 Authorization。
    // saveToken 内部补 'Bearer ' 前缀 + 经注入的 SecureStorageTokenStorage 落盘（F277 strip）。
    if (result case XbSuccess(:final data)) {
      try {
        await _sdk.saveToken(data);
      } catch (_) {
        // 存储失败不改变登录结果（Property 1 永不抛）；下次启动需重登。
      }
    }
    return result;
  }

  @override
  Future<XbResult<bool>> register(
    String email,
    String password, {
    String? emailCode,
    String? inviteCode,
  }) async {
    // SdkResult 形态 + D69 email 预处理。register 不返 token（F407），DD-9 由 UI 层二步调 login。
    final r = await _sdk.auth.registerResult(
      email.toLowerCase().trim(),
      password,
      emailCode: emailCode,
      inviteCode: inviteCode,
    );
    return _fromSdkResult(r, (ok) => ok);
  }

  @override
  Future<XbResult<bool>> sendEmailVerifyCode(String email) async {
    // SdkResult 形态。失败可能含 BusinessError(emailVerifyCodeRateLimit) 60s 限流（F359，HTTP 400）。
    final r = await _sdk.auth.sendEmailVerifyCodeResult(email.toLowerCase().trim());
    return _fromSdkResult(r, (ok) => ok);
  }

  @override
  Future<XbResult<bool>> forgotPassword(
    String email,
    String code,
    String newPassword,
  ) async {
    // throw 形态（SDK forgotPassword 无 Result 变体）。
    return _guard('forgotPassword',
        () => _sdk.auth.forgotPassword(email.toLowerCase().trim(), code, newPassword));
  }

  @override
  Future<XbResult<void>> logout() async {
    // W3.6 数据层 logout（数据一致性总章 § B）—— θ-8 in-flight race 防御 + θ-2 服务端撤销。
    //
    // 本方法负责「SDK / token」侧（step 0 + step 5）；完整 7 步中的离线缓存清理（step 2）、
    // 订阅 path 清理（step 3）、外挂索引 + profile 删除（step 4）依赖 W4/W6/W7 才建的
    // drift 索引表 + SharedPreferences 缓存，在那些 wave 接入（已留 hook：success 写回均经
    // _writeIfNotLoggingOut 守卫，logout 期间丢弃）。authState 切换（step 6）由
    // AuthStateNotifier.logout() 编排（需 ref，见 auth_state_provider.dart）。
    _isLoggingOut = true; // 🔴 θ-8：先置 flag，确保清理期间任何 in-flight success 被丢弃
    try {
      // step 0：服务端撤销（θ-2，fire-and-forget + 3s timeout，失败不阻塞本地）。
      // 注：XBoard 后端无 logout 端点，SDK auth.logout() 当前是 no-op 返 true；step 0 保留
      // 调用点，待后端支持 token 撤销（v0.2 / refresh token 模型）时天然生效。
      try {
        await _sdk.auth.logout().timeout(const Duration(seconds: 3));
      } catch (_) {
        // 服务端撤销失败不阻塞本地清理（最大努力）。
      }

      // step 5：清本地 token —— 调 SDK clearToken() 清注入的 TokenStorage
      // （SecureStorageTokenStorage → 删 xb_access_token_v1；SDK auth.logout() 不碰 token）。
      // step 2（部分）：清 R6 订阅离线缓存（W4.4 已建 SubscriptionCache；需在清 token 前取 hash）。
      try {
        final token = await _sdk.getToken();
        await _subscriptionCache.clear(token: token);
      } catch (_) {
        // 清缓存失败不阻塞（最大努力）。
      }
      try {
        await _sdk.clearToken();
      } catch (_) {
        // 清 token 失败（storage 异常）也不抛 —— Property 1 永不抛。
      }

      return XbResult.success(null);
    } finally {
      _isLoggingOut = false; // 解除 flag（authState 已由编排层切，cache 写回也无害）
    }
  }

  @override
  Future<XbResult<XbDomainSubscription>> getSubscription() async {
    // throw 形态（_guard 归一）+ SubscriptionModel → XbDomainSubscription 映射（R6.8）。
    final result = await _guard('getSubscription', () async {
      final m = await _sdk.subscription.getSubscription();
      return XbDomainSubscription(
        email: m.email ?? '',
        uuid: m.uuid ?? '',
        planName: m.planName,
        totalBytes: m.transferEnable ?? 0, // 字节（F408）
        usedBytes: (m.u ?? 0) + (m.d ?? 0), // R6.8 已用 = u + d（字节）
        expiredAt: m.expiredAt,
        nextResetAt: m.nextResetAt,
        resetDay: m.resetDay,
        planId: m.planId,
      );
    });
    // R6 离线缓存 success 即写（决策 #11 / W4.4）：θ-8 守卫 logout 期间丢弃。
    // 缓存写失败绝不影响返回结果（Property 1 永不抛）—— 整体 try/catch 吞掉。
    if (result case XbSuccess(:final data)) {
      try {
        await _writeIfNotLoggingOut(() async {
          final token = await _sdk.getToken();
          await _subscriptionCache.write(data, token: token);
        });
      } catch (_) {
        // 缓存写失败（storage 异常 / 平台 binding 未初始化等）不影响在线数据返回。
      }
    }
    return result;
  }

  @override
  Future<XbResult<String>> getSubscribeUrl() async =>
      _guard('getSubscribeUrl', () => _sdk.subscription.getSubscribeUrl());

  @override
  Future<XbResult<XbCheckLogin>> checkLogin() async => _guard(
        'checkLogin',
        () async {
          final r = await _sdk.user.checkLogin();
          return XbCheckLogin(isLogin: r.isLogin);
        },
      );

  @override
  Future<XbResult<List<PlanItem>>> getPlans() async =>
      _notImpl('getPlans'); // W7.1

  @override
  Future<XbResult<String>> createOrder(
    int planId,
    XbPlanPeriod period, {
    String? couponCode,
  }) async =>
      _notImpl('createOrder'); // W7.2

  @override
  Future<XbResult<CheckoutOutcomeUi>> checkout(
    String tradeNo,
    String method,
  ) async =>
      _notImpl('checkout'); // W7.2

  @override
  Future<XbResult<XbPagedList<OrderSummary>>> getOrders({
    int page = 1,
    int pageSize = 20,
  }) async =>
      _notImpl('getOrders'); // W7.6

  @override
  Future<XbResult<OrderDetail?>> getOrder(String tradeNo) async =>
      _notImpl('getOrder'); // W7.6

  @override
  Future<XbResult<bool>> cancelOrder(String tradeNo) async =>
      _notImpl('cancelOrder'); // W7.x

  @override
  Future<XbResult<CouponInfo?>> checkCoupon(
    String code,
    int planId,
    XbPlanPeriod period,
  ) async =>
      _notImpl('checkCoupon'); // W7.2

  @override
  Future<XbResult<List<PaymentMethodItem>>> getPaymentMethods() async =>
      _notImpl('getPaymentMethods'); // W7.2

  @override
  Future<XbResult<IpMirrorConfigUi>> fetchMirrorList() async =>
      _notImpl('fetchMirrorList'); // W6.5

  @override
  void fireAllMirrors(List<String> urls) {
    // W6.5 填实 fire-and-forget；Property 1 例外（void 不返结果）。
  }
}
