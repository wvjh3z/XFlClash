/// 反腐层实现：在此消费 SDK 面板业务接口并映射为客户端领域模型。
/// 基础设施 provider 可通过 show 限定导入已登记的公共会话类型。
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
/// 会话结束永久封住旧实例；每次请求还核对 SDK revision，拒绝旧响应与跨账号重试。
library;

import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart';

import '../config/xboard_config.dart';
import '../models/checkout_outcome_ui.dart' as ui;
import '../models/confirmed_order.dart';
import '../models/order_summary.dart';
import '../models/plan_item.dart';
import '../models/xb_domain_error.dart';
import '../models/xb_domain_subscription.dart';
import '../models/xb_domain_types.dart';
import '../models/xb_invite.dart';
import '../models/xb_notice.dart';
import '../models/xb_result.dart';
import '../models/xb_tutorial.dart';
import '../services/sentry_bootstrap.dart';
import '../services/withdraw_eligibility.dart' show withdrawMinimumPaidRecords;
import '../util/pii_mask.dart';
import '../util/subscription_cache.dart';
import '../util/tutorial_resource_base.dart';
import 'guest_catalog.dart';
import 'xboard_service.dart';
import '../util/money_input.dart';

part 'confirmed_order_decision.dart';

/// 使用教程取自知识库的「官方客户端」分类（用户确认的确切分类名）。
const String _kTutorialCategory = '官方客户端';
const String _ipTutorialCategory = '改IP教程';

class XboardServiceImpl
    implements
        XboardService,
        XboardSessionLifecycle,
        XboardTutorialRequestControl,
        XboardInviteRequestControl,
        XboardAuthenticationRequestControl,
        XboardGuestCatalogControl,
        XboardProgressOrderControl {
  XboardServiceImpl({
    required XBoardSDK sdk,
    SubscriptionCache? subscriptionCache,
    Future<void> Function()? apiFailover,
  }) : _sdk = sdk,
       _subscriptionCache = subscriptionCache ?? SubscriptionCache(),
       _apiFailover = apiFailover {
    _boundSdkRevision = _sdkRevision;
  }

  final XBoardSDK _sdk;
  String? _tutorialResourceBase;

  Future<String?> _readTutorialResourceBase() async {
    final configured = tutorialResourceBase(
      XboardConfig.current.tutorialBaseUrl,
    )?.toString();
    if (configured != null) return configured;
    if (_tutorialResourceBase != null) return _tutorialResourceBase;
    var active = true;
    try {
      // This auxiliary request has its own lifetime inside the article scope.
      final config = await _withValidity(
        () => active,
        () => _sdk.config.getConfig(),
      ).timeout(const Duration(seconds: 3));
      return _tutorialResourceBase = tutorialResourceBase(
        config.appUrl,
      )?.toString();
    } catch (_) {
      return null;
    } finally {
      active = false;
    }
  }

  /// R6 离线缓存（决策 #11 success-write，W4.4）。
  final SubscriptionCache _subscriptionCache;

  /// API 域名故障转移钩子（注入 `EndpointRaceController.failOverApi`）：
  /// API 请求遇网络/服务端错误时调一次，切到候选里可达的域名，再重试一次（统一收口，
  /// 所有 17 个 API 方法自动受益，UI 的「重新加载」天然走到换域名重试）。null = 未注入
  /// （测试 / SDK 未就绪）→ 退化为不重试（行为同旧版）。
  final Future<void> Function()? _apiFailover;

  bool _isLoggingOut = false;
  int _operationEpoch = 0;
  late final int? _boundSdkRevision;

  int? get _sdkRevision {
    try {
      return _sdk.authSession.revision;
    } catch (_) {
      // 未初始化 SDK / 旧测试替身没有会话快照；生产 bootstrap 后总有 revision。
      return null;
    }
  }

  bool _isCurrent(int epoch, int? revision) =>
      !_isLoggingOut &&
      _operationEpoch == epoch &&
      _boundSdkRevision == revision &&
      _sdkRevision == revision;

  XbResult<T> _stale<T>() => XbResult.failure(
    XbDomainError.network(NetworkErrorKind.cancelled, '请求所属会话已结束'),
  );

  @override
  void invalidateSessionRequests() {
    _operationEpoch++;
    _isLoggingOut = true;
  }

  @override
  Future<void> endSession({
    required String? ownerHash,
    required int? sdkRevision,
    required bool expired,
  }) async {
    invalidateSessionRequests();
    // SDK 已自动失效时不再清 Token；手动退出只清被捕获的 revision。
    // 不能在慢 Profile/cache 清理完成后无条件清当前 Token。
    if (!expired && sdkRevision != null) {
      try {
        await _sdk.clearTokenIfSession(sdkRevision);
      } catch (e, s) {
        SentryBootstrap.captureException(
          e,
          stackTrace: s,
          where: 'auth token delete',
        );
      }
    }
    if (ownerHash != null && ownerHash != 'anon') {
      await _subscriptionCache.clearForOwner(ownerHash);
    }
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
    ServerError(:final httpStatusCode) => XbDomainError.server(
      httpStatusCode,
      e.message,
    ),
    SecurityError() => XbDomainError.security(e.message),
    UnexpectedError(:final operation) => XbDomainError.unexpected(
      operation,
      e.message,
    ),
  };

  /// throw 形态归一（design L797-833 + C37）：旧异常体系 3 子类 + catch-all 兜底。
  ///
  /// broad catch（θ-11）拦截 SDK 内部 `fromJson` 的 `TypeError` 等，走 XbUnexpected 不闪退。
  Future<T> _withValidity<T>(
    bool Function() current,
    Future<T> Function() body,
  ) {
    try {
      return _sdk.httpService.withRequestValidity(current, body);
    } catch (_) {
      return body();
    } // Legacy test adapters have no HTTP service.
  }

  @override
  Future<T> withInviteRequestValidity<T>(
    bool Function() isActive,
    Future<T> Function() body,
  ) => _withValidity(isActive, body);

  static const _writeOperations = {
    'register',
    'sendEmailVerifyCode',
    'forgotPassword',
    'createOrder',
    'checkout',
    'cancelOrder',
    'generateInviteCode',
    'withdrawCommission',
    'transferCommissionToBalance',
  };
  final Set<String> _writesInFlight = {};
  bool _inviteCreationUnconfirmed = false;

  // Service instances can be rebuilt without a new authenticated session.
  // Keep the order lock and uncertainty across those replacements, not across
  // SDK auth revisions. Never persist an order number or guess a missing one.
  static final _orderSessions = Expando<_OrderDecisionSession>();

  _OrderDecisionSession _orderSession(int? revision) {
    final existing = _orderSessions[_sdk];
    if (existing != null && existing.revision == revision) return existing;
    final next = _OrderDecisionSession(revision);
    _orderSessions[_sdk] = next;
    return next;
  }

  bool _uncertain(XbDomainError error) =>
      error is XbServer ||
      error is XbUnexpected ||
      (error is XbNetwork && error.kind != NetworkErrorKind.cancelled);

  Future<XbResult<T>> _write<T>(
    String operation,
    Future<XbResult<T>> Function() body, {
    String? tradeNo,
    Future<XbResult<void>> Function()? preflight,
  }) async {
    final epoch = _operationEpoch;
    final revision = _sdkRevision;
    bool current() => _isCurrent(epoch, revision);
    if (!current()) return _stale<T>();
    // Checkout and cancel cannot overlap, even from separate page instances.
    final key = switch (operation) {
      'createOrder' || 'checkout' || 'cancelOrder' => 'orders',
      'withdrawCommission' || 'transferCommissionToBalance' => 'commission',
      _ => operation,
    };
    final locks = key == 'orders'
        ? _orderSession(revision).writes
        : _writesInFlight;
    if (!locks.add(key)) {
      return const XbFailure(
        XbBusiness(BusinessErrorKind.generic, '上一项操作仍在处理或核对，请勿重复提交。', null),
      );
    }
    try {
      if (preflight != null) {
        final ready = await preflight();
        if (!current()) return _stale<T>();
        if (ready case XbFailure<void>(:final error)) return XbFailure(error);
      }
      var result =
          operation == 'generateInviteCode' && _inviteCreationUnconfirmed
          ? XbResult<T>.failure(
              const XbUnconfirmed('generateInviteCode', '正在核对邀请码'),
            )
          : await body();
      if (!current()) return _stale<T>();
      // Defensive boundary for legacy/custom SDK adapters returning false.
      if (result is XbSuccess<T> && result.data == false) {
        result = XbResult<T>.failure(XbUnconfirmed(operation, '操作结果尚未确认'));
      }
      if (result is! XbFailure<T> ||
          (!_uncertain(result.error) && result.error is! XbUnconfirmed)) {
        return result;
      }
      if (operation == 'generateInviteCode') _inviteCreationUnconfirmed = true;
      String advice;
      switch (operation) {
        case 'createOrder':
          final orders = await getOrders(forceRefresh: true);
          advice = orders is XbSuccess
              ? '已刷新订单列表，请前往“我的订单”核对，勿重复下单。'
              : '暂时无法查询订单，请稍后到“我的订单”核对，勿重复下单。';
        case 'checkout':
        case 'cancelOrder':
          final detail = await getOrder(tradeNo!);
          if (!current()) return _stale<T>();
          final order = detail is XbSuccess<OrderDetail?> ? detail.data : null;
          if (order != null && order.summary.tradeNo == tradeNo) {
            if (operation == 'checkout' &&
                order.summary.status == XbOrderStatus.completed) {
              return XbSuccess(const ui.CheckoutPaid() as T);
            }
            if (operation == 'cancelOrder' &&
                order.summary.status == XbOrderStatus.cancelled) {
              return XbSuccess(true as T);
            }
          }
          advice = '请检测该订单的最新状态，勿重复支付或取消。';
        case 'generateInviteCode':
          final info = await _guard(
            'getInviteInfo',
            () => _sdk.invite.getInviteInfo(),
          );
          if (!current()) return _stale<T>();
          if (info is XbSuccess<InviteInfoModel>) {
            final usable = info.data.codes.where(
              (c) => c.isActive && c.code.trim().isNotEmpty,
            );
            if (usable.isNotEmpty) {
              _inviteCreationUnconfirmed = false;
              return XbSuccess(usable.first.code as T);
            }
          }
          advice = '请刷新邀请码核对；本次会话不会自动重复生成。';
        case 'withdrawCommission':
        case 'transferCommissionToBalance':
          await getInviteInfo();
          advice = '请核对余额及相关申请记录，勿重复提交；余额变化不能单独证明本次操作成功。';
        case 'register':
          advice = '请尝试登录确认账号是否已注册，勿立即重复注册。';
        case 'sendEmailVerifyCode':
          advice = '请先检查邮箱及垃圾邮件，稍后再申请验证码。';
        case 'forgotPassword':
          advice = '请尝试使用新密码登录确认，勿立即重复修改。';
        default:
          advice = '请先核对操作结果，勿重复提交。';
      }
      if (!current()) return _stale<T>();
      return XbFailure(
        XbUnconfirmed(operation, '操作结果尚未确认。$advice 如问题持续，请向客服反馈此问题。'),
      );
    } finally {
      locks.remove(key);
    }
  }

  Future<XbResult<T>> _guard<T>(
    String operation,
    Future<T> Function() body, {
    bool Function()? isActive,
  }) => _writeOperations.contains(operation)
      ? _write(
          operation,
          () => _guardOnce(operation, body, isActive: isActive),
        )
      : _guardOnce(operation, body, isActive: isActive);

  Future<XbResult<T>> _guardOnce<T>(
    String operation,
    Future<T> Function() body, {
    bool Function()? isActive,
  }) async {
    final epoch = _operationEpoch;
    final revision = _sdkRevision;
    bool current() => _isCurrent(epoch, revision) && (isActive?.call() ?? true);
    if (!current()) return _stale<T>();
    final first = await _runGuarded(
      operation,
      () => _withValidity(current, body),
    );
    if (!current()) return _stale<T>();
    // 失败且可换域名挽救（网络/服务端类）→ failOver 切域名后重试一次。业务/鉴权类换域名无用，不重试。
    if (first case XbFailure(
      :final error,
    ) when _mayLegacyFailover(operation) && _shouldFailover(error)) {
      final hook = _apiFailover;
      if (hook != null) {
        try {
          await hook();
        } catch (_) {
          // failOver 内部永不抛；保险吞错。
        }
        if (!current()) return _stale<T>();
        final retry = await _runGuarded(
          operation,
          () => _withValidity(current, body),
        );
        return current() ? retry : _stale<T>();
      }
    }
    return first;
  }

  /// 单次执行 + 异常归一（原 _guard 主体，拆出来供 failover 重试复用）。
  Future<XbResult<T>> _runGuarded<T>(
    String operation,
    Future<T> Function() body,
  ) async {
    try {
      return XbResult.success(await body());
    } on AuthException catch (e) {
      return XbResult.failure(XbDomainError.unauthorized(e.message));
    } on EndpointException catch (e) {
      return XbResult.failure(XbDomainError.server(e.code ?? 0, e.message));
    } on RequestNotDispatchedException catch (e) {
      return XbResult.failure(
        XbDomainError.network(NetworkErrorKind.cancelled, e.message),
      );
    } on NetworkException catch (e) {
      return XbResult.failure(
        XbDomainError.network(NetworkErrorKind.unknown, e.message),
      );
    } on ApiException catch (e) {
      return XbResult.failure(
        XbDomainError.business(BusinessErrorKind.generic, e.message, null),
      );
    } catch (e, s) {
      // #1 监测：θ-11 catch-all = SDK 抛了未预期异常（fromJson TypeError / 后端结构变更等）。
      // 「本不该发生」的盲区 → 上报 Sentry（带 operation 上下文）。预期错（auth/network/business
      // 已在上面分流）不报，零噪音；dsn 空 → no-op。
      SentryBootstrap.captureException(
        e,
        stackTrace: s,
        where: 'api:$operation',
      );
      return XbResult.failure(
        XbDomainError.unexpected(operation, e.toString()),
      );
    }
  }

  /// 该错误是否值得「换域名重试」：仅网络不可达 / 服务端故障（当前域名被墙或挂了，换一个可能通）。
  /// 鉴权失效、业务错误（如优惠码无效）、安全错误换域名也救不了 → 不重试，避免无谓延迟。
  bool _mayLegacyFailover(String operation) {
    try {
      if (_sdk.httpService.endpointRecoveryEnabled) return false;
    } catch (_) {
      /* Legacy test adapters do not expose HTTP infrastructure. */
    }
    return const {
      'login',
      'getEmailSuffixes',
      'getSubscription',
      'getSubscribeUrl',
      'getPlans',
      'getOrders',
      'getOrder',
      'checkCoupon',
      'getPaymentMethods',
      'getInviteInfo',
      'getCommissionRecords',
      'getWithdrawalRecordCount',
      'getWithdrawMethods',
      'getShareLink',
      'getTutorials',
      'getTutorialDetail',
      'getNotices',
    }.contains(operation);
  }

  static bool _shouldFailover(XbDomainError error) => switch (error) {
    XbNetwork() => true,
    XbServer() => true,
    _ => false,
  };

  /// SdkResult 形态归一（switch 解构，Success/Failure 非 Ok/Err，F410）。
  XbResult<R> _fromSdkResult<S, R>(SdkResult<S> r, R Function(S data) map) =>
      switch (r) {
        Success(:final data) => XbResult.success(map(data)),
        Failure(:final error) => XbResult.failure(_mapError(error)),
      };

  /// SdkResult 形态 + 异常防御（Property 1）：SDK adapter 理论上返 SdkResult 不抛，但若意外
  /// 抛（panel TypeError / 未预期）也归一为 XbUnexpected，绝不向 UI 抛（θ-11）。
  Future<XbResult<R>> _guardSdkResult<S, R>(
    String operation,
    Future<SdkResult<S>> Function() body,
    R Function(S data) map,
  ) => _writeOperations.contains(operation)
      ? _write(operation, () => _guardSdkResultOnce(operation, body, map))
      : _guardSdkResultOnce(operation, body, map);

  Future<XbResult<R>> _guardSdkResultOnce<S, R>(
    String operation,
    Future<SdkResult<S>> Function() body,
    R Function(S data) map,
  ) async {
    final epoch = _operationEpoch;
    final revision = _sdkRevision;
    if (!_isCurrent(epoch, revision)) return _stale<R>();
    final first = await _runGuardedSdk(
      operation,
      () => _withValidity(() => _isCurrent(epoch, revision), body),
      map,
    );
    if (!_isCurrent(epoch, revision)) return _stale<R>();
    if (first case XbFailure(
      :final error,
    ) when _mayLegacyFailover(operation) && _shouldFailover(error)) {
      final hook = _apiFailover;
      if (hook != null) {
        try {
          await hook();
        } catch (_) {}
        if (!_isCurrent(epoch, revision)) return _stale<R>();
        final retry = await _runGuardedSdk(
          operation,
          () => _withValidity(() => _isCurrent(epoch, revision), body),
          map,
        );
        return _isCurrent(epoch, revision) ? retry : _stale<R>();
      }
    }
    return first;
  }

  Future<XbResult<R>> _runGuardedSdk<S, R>(
    String operation,
    Future<SdkResult<S>> Function() body,
    R Function(S data) map,
  ) async {
    try {
      return _fromSdkResult(await body(), map);
    } catch (e, s) {
      // #1 监测：SDK adapter 理论返 SdkResult 不抛，真抛 = 未预期（panel TypeError 等）→ 上报。
      SentryBootstrap.captureException(
        e,
        stackTrace: s,
        where: 'api:$operation',
      );
      return XbResult.failure(
        XbDomainError.unexpected(operation, e.toString()),
      );
    }
  }

  // ───────── 18 方法（逐 wave 填实；fireAllMirrors 是 void 例外）─────────

  @override
  Future<XbResult<String>> login(String email, String password) =>
      loginForRequest(email, password, isActive: () => true);

  @override
  Future<XbResult<String>> loginForRequest(
    String email,
    String password, {
    required bool Function() isActive,
    Future<bool> Function(String token)? establish,
  }) async {
    if (!isActive()) return _stale<String>();
    final epoch = _operationEpoch;
    final revision = _sdkRevision;
    // SdkResult 形态 + Property 1 异常防御（D69 email 预处理 trim+lowercase）。
    final result = await _guardSdkResult<String, String>(
      'login',
      () => _withValidity(isActive,
          () => _sdk.auth.loginResult(email.toLowerCase().trim(), password)),
      (token) => token, // data 已是鉴权 token（F406）
    );
    // 🔴 W3.9（F406 致命语义）：SDK `auth.loginResult` **不自动存 token**（只有便捷方法
    // `loginWithCredentials` 才存）；反腐层必须显式 saveToken，否则后续 API 无 Authorization。
    if (result case XbSuccess(:final data)) {
      try {
        if (!isActive()) return _stale<String>();
        if (revision == null) {
          return XbResult.failure(XbDomainError.unexpected('login', '认证服务未就绪'));
        }
        final saved = await _sdk.saveTokenIfSession(data, revision);
        if (saved == null) return _stale<String>();
        if (_operationEpoch != epoch || _isLoggingOut || !isActive()) {
          // 慢 save 已入队，退出未必能清其新 revision。只撤销本次保存，保留后来的 B。
          await _sdk.clearTokenIfSession(saved.revision);
          return _stale<String>();
        }
        if (_sdkRevision != saved.revision) return _stale<String>();
        if (establish != null) {
          // Retain the exact saved revision across client establishment. Token
          // text alone cannot identify ownership when a later login saves the
          // same credentials again.
          final bool established;
          try {
            established = await establish(data);
          } catch (_) {
            await _sdk.clearTokenIfSession(saved.revision);
            rethrow;
          }
          if (!established) {
            await _sdk.clearTokenIfSession(saved.revision);
            return _stale<String>();
          }
        }
      } catch (e, s) {
        SentryBootstrap.captureException(
          e,
          stackTrace: s,
          where: 'auth token save',
        );
        return XbResult.failure(
          XbDomainError.unexpected('login', '登录信息保存失败，请重试'),
        );
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
    // SdkResult 形态 + Property 1 异常防御。register 不返 token（F407），DD-9 由 UI 层二步调 login。
    return _guardSdkResult<bool, bool>(
      'register',
      () => _sdk.auth.registerResult(
        email.toLowerCase().trim(),
        password,
        emailCode: emailCode,
        inviteCode: inviteCode,
      ),
      (ok) => ok,
    );
  }

  @override
  Future<XbResult<bool>> sendEmailVerifyCode(String email) async {
    // SdkResult 形态 + Property 1。失败可能含 BusinessError(emailVerifyCodeRateLimit) 60s 限流（F359，HTTP 400）。
    return _guardSdkResult<bool, bool>(
      'sendEmailVerifyCode',
      () => _sdk.auth.sendEmailVerifyCodeResult(email.toLowerCase().trim()),
      (ok) => ok,
    );
  }

  @override
  Future<XbResult<bool>> forgotPassword(
    String email,
    String code,
    String newPassword,
  ) async {
    // throw 形态（SDK forgotPassword 无 Result 变体）。
    return _guard(
      'forgotPassword',
      () => _sdk.auth.forgotPassword(
        email.toLowerCase().trim(),
        code,
        newPassword,
      ),
    );
  }

  @override
  Future<XbResult<void>> logout() async {
    try {
      final snapshot = _sdk.authSession;
      String? owner;
      try {
        owner = userIdHashFromToken(await _sdk.getToken());
      } catch (e, s) {
        SentryBootstrap.captureException(
          e,
          stackTrace: s,
          where: 'logout owner',
        );
      }
      await endSession(
        ownerHash: owner,
        sdkRevision: snapshot.revision,
        expired: false,
      );
      return XbResult.success(null);
    } catch (e, s) {
      SentryBootstrap.captureException(
        e,
        stackTrace: s,
        where: 'logout local cleanup',
      );
      return XbResult.failure(
        XbDomainError.unexpected('logout', '部分本地会话数据清理失败'),
      );
    }
  }

  @override
  Future<XbResult<List<String>>> getEmailSuffixes() async =>
      // form-a R5.6：取注册白名单后缀。throw 形态（getConfig 抛异常）→ _guard 归一。
      // 空列表 = 白名单禁用（F208 语义，UI 据此放开任意后缀输入）。
      _guard('getEmailSuffixes', () async {
        final cfg = await _sdk.config.getConfig();
        return cfg.emailWhitelistSuffix;
      });

  @override
  Future<XbResult<XbDomainSubscription>> getSubscription() async {
    final epoch = _operationEpoch;
    final revision = _sdkRevision;
    String? token;
    try {
      token = await _sdk.getToken();
    } catch (_) {
      // 缓存不可用不影响在线错误归一。
    }
    if (!_isCurrent(epoch, revision)) return _stale<XbDomainSubscription>();
    // 网络发起前捕获原归属，不能响应后读取新账号 Token。
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
        await _subscriptionCache.write(
          data,
          token: token,
          isSessionCurrent: () => _isCurrent(epoch, revision),
        );
      } catch (_) {
        // 缓存写失败（storage 异常 / 平台 binding 未初始化等）不影响在线数据返回。
      }
    }
    return _isCurrent(epoch, revision)
        ? result
        : _stale<XbDomainSubscription>();
  }

  @override
  Future<XbResult<String>> getSubscribeUrl() async =>
      _guard('getSubscribeUrl', () => _sdk.subscription.getSubscribeUrl());

  @override
  Future<XbResult<XbCheckLogin>> checkLogin() async =>
      _guard('checkLogin', () async {
        final r = await _sdk.user.checkLogin();
        return XbCheckLogin(isLogin: r.isLogin);
      });

  @override
  Future<XbResult<List<PlanItem>>> getGuestCatalog() =>
      loadGuestCatalog(_sdk.baseUrl, _mapPlan);

  @override
  Future<XbResult<List<PlanItem>>> getPlans() async =>
      _guard('getPlans', () async {
        final plans = await _sdk.plan.getPlans();
        return plans.map(_mapPlan).toList();
      });

  @override
  Future<XbResult<String?>> confirmOrder(
    ConfirmedOrderQuote quote, {
    required bool Function() isActive,
    required Future<bool> Function(ConfirmedOrderConflict) confirm,
    void Function(ConfirmedOrderStage stage)? onStage,
  }) async {
    final epoch = _operationEpoch;
    final revision = _sdkRevision;
    bool current() =>
        revision != null &&
        _isCurrent(epoch, revision) &&
        _sdk.authSession.state == AuthState.authenticated &&
        isActive();
    if (!current()) return const XbSuccess(null);
    final session = _orderSession(revision);
    if (!session.writes.add('orders')) {
      return const XbFailure(
        XbBusiness(BusinessErrorKind.generic, '订单正在处理，请勿重复提交。', null),
      );
    }
    try {
      return await _sdk.httpService.withRequestValidity(
        current,
        () => _decideConfirmedOrder(session, quote, current, confirm, onStage),
      );
    } finally {
      session.writes.remove('orders');
    }
  }

  @override
  Future<XbResult<String>> createOrder(
    int planId,
    XbPlanPeriod period, {
    String? couponCode,
  }) async =>
      // SDK createOrder 收 String（PlanPeriod.value，旧版 *_price 命名 F338）→ 返 tradeNo。
      _guard(
        'createOrder',
        () => _sdk.order.createOrder(
          planId,
          _toSdkPeriod(period).value,
          couponCode: couponCode,
        ),
      );

  @override
  Future<XbResult<ui.CheckoutOutcomeUi>> checkout(
    String tradeNo,
    String method,
  ) => _write(
    'checkout',
    () => _guardOnce('checkout', () async {
      final outcome = await _withKnownWriteRejection(
        () => _sdk.order.checkoutOrder(tradeNo, method),
      );
      final mapped = _mapCheckout(outcome);
      if (mapped is ui.CheckoutFailed) {
        throw EndpointException('结算响应无法确认', 200);
      }
      return mapped;
    }),
    tradeNo: tradeNo,
    preflight: () => _preflightOrderWrite(tradeNo, 'checkout'),
  );

  @override
  Future<XbResult<XbPagedList<OrderSummary>>> getOrders({
    int page = 1,
    int pageSize = 20,
    bool forceRefresh = false,
  }) async => _guard('getOrders', () async {
    final paged = await _sdk.order.getOrders(
      page: page,
      pageSize: pageSize,
      forceRefresh: forceRefresh,
    );
    return XbPagedList<OrderSummary>(
      items: paged.data
          .map(_mapOrderSummary)
          .toList(), // PaginatedList.data（第12轮）
      page: page,
      pageSize: pageSize,
      total: paged.total,
    );
  });

  @override
  Future<XbResult<OrderDetail?>> getOrder(String tradeNo) =>
      _guardOnce('getOrder', () => _verifiedOrderDetail(tradeNo));

  @override
  Future<XbResult<bool>> cancelOrder(String tradeNo) => _write(
    'cancelOrder',
    () => _guardOnce(
      'cancelOrder',
      () => _withKnownWriteRejection(() => _sdk.order.cancelOrder(tradeNo)),
    ),
    tradeNo: tradeNo,
    preflight: () => _preflightOrderWrite(tradeNo, 'cancelOrder'),
  );

  @override
  Future<XbResult<CouponInfo?>> checkCoupon(
    String code,
    int planId,
    XbPlanPeriod period,
  ) async =>
      // SDK checkCoupon 收 SDK PlanPeriod（非 String，第12轮非对称）。
      _guard('checkCoupon', () async {
        final m = await _sdk.order.checkCoupon(
          code,
          planId,
          _toSdkPeriod(period),
        );
        if (m == null) return null;
        return CouponInfo(
          code: code,
          type: m.type ?? 0, // CouponModel.type int? → 兜底（第12轮）
          value: m.value ?? 0,
          endedAt: m.endedAt,
        );
      });

  @override
  Future<XbResult<List<PaymentMethodItem>>> getPaymentMethods() async =>
      // payment adapter 无参 getPaymentMethods（非 order.getPaymentMethods(tradeNo)，第12轮）。
      _guard('getPaymentMethods', () async {
        final methods = await _sdk.payment.getPaymentMethods();
        return methods.where((m) => m.isAvailable && m.id.trim().isNotEmpty).map(_mapPaymentMethod).toList();
      });

  @override
  Future<XbResult<IpMirrorConfigUi>> fetchMirrorList() async =>
      _guard('fetchMirrorList', () async {
        final cfg = await _sdk.ipMirror.fetchMirrorList();
        return IpMirrorConfigUi(
          enabled: cfg.enabled,
          urls: cfg.urls,
          throttle: cfg.throttle,
          fetchTimeout: cfg.fetchTimeout,
        );
      });

  @override
  void fireAllMirrors(List<String> urls) {
    // R7.13.bis fire-and-forget；Property 1 例外（void 不返结果）。
    try {
      _sdk.ipMirror.fireAllMirrors(urls);
    } catch (_) {
      // fire-and-forget：错误静默（全部不可达也不影响功能，用户 2026-05-27 锁定）。
    }
  }

  // ───────── 邀请返佣 + 分享好友（form-a 邀请功能）─────────

  @override
  Future<XbResult<XbInviteInfo>> getInviteInfo() async =>
      // throw 形态（_guard 归一）。合并两数据源：invite 统计（注册数/佣金/比例/可用佣金 + 邀请码）
      // + user 余额（账户余额 balance）。并发拉取，任一失败 → _guard 捕获归一为 XbFailure。
      _guard('getInviteInfo', () async {
        final results = await Future.wait([
          _sdk.invite.getInviteInfo(),
          _sdk.user.getUserInfo(),
        ]);
        final info = results[0] as InviteInfoModel;
        final user = results[1] as UserModel;
        // Never display used/blank codes as a fallback.
        final active = info.codes.where(
          (c) => c.isActive && c.code.trim().isNotEmpty,
        );
        final code = active.isNotEmpty ? active.first.code : null;
        return XbInviteInfo(
          code: code,
          registeredCount: info.totalInvites,
          pendingYuan: info.pendingCommission / 100, // stat[2] cents → yuan
          totalYuan: info.totalCommission / 100, // stat[1] cents → yuan
          commissionRate: info.commissionRate, // stat[3] 百分比整数
          commissionBalanceYuan:
              user.commissionBalanceInYuan, // user.commission_balance/100
          accountBalanceYuan: user.balanceInYuan, // user.balance/100
        );
      });

  @override
  Future<XbResult<Uri>> getOfficialSiteUrl({required bool quickLogin, required bool Function() isActive}) {
    final epoch = _operationEpoch;
    final revision = _sdkRevision;
    bool current() => isActive() && _isCurrent(epoch, revision) &&
        (!quickLogin || _sdk.authSession.state == AuthState.authenticated);
    return _guard('getOfficialSiteUrl', () async {
      final config = await _sdk.config.getConfig();
      Uri? webUrl(String value) {
        final uri = Uri.tryParse(value.trim());
        return uri != null && uri.isScheme('https') && uri.host.isNotEmpty &&
            !uri.authority.contains('@') && !value.contains('\\') ? uri : null;
      }
      final site = webUrl(config.appUrl);
      if (site == null) throw const FormatException('官网地址未配置或无效');
      if (!quickLogin) return site;
      if (!current()) throw RequestNotDispatchedException('登录状态已变化');
      final response = await _sdk.httpService.postRequest('/api/v1/user/getQuickLoginUrl', {'redirect':'dashboard'});
      final raw = response['data'];
      final link = raw is String ? webUrl(raw) : null;
      final route = link == null ? null : Uri.tryParse(link.fragment);
      if (response['success'] == false || link == null || link.origin != site.origin ||
          route?.path != '/login' || (route?.queryParameters['verify'] ?? '').isEmpty ||
          route?.queryParameters['redirect'] != 'dashboard') {
        throw const FormatException('官网快捷登录链接无效');
      }
      return link;
    }, isActive: current);
  }

  @override
  Future<XbResult<String>> generateInviteCode() async =>
      // throw 形态。SDK 两步（save + fetch）返回新邀请码 code 字符串。
      _guard('generateInviteCode', () => _sdk.invite.generateInviteCode());

  @override
  Future<XbResult<List<XbCommissionRecord>>> getCommissionRecords({
    int page = 1,
    int pageSize = 20,
  }) async => _guard('getCommissionRecords', () async {
    final details = await _sdk.invite.getCommissionDetails(
      page: page,
      pageSize: pageSize,
    );
    return details
        .map(
          (d) => XbCommissionRecord(
            id: d.id,
            getAmountYuan: d.getAmountInYuan, // get_amount cents → yuan
            createdAt: d.createdAt,
          ),
        )
        .toList();
  });

  @override
  Future<XbResult<int>> getWithdrawalRecordCount() => _guard('getWithdrawalRecordCount', () async {
    // The SDK's row DTO loses the distinction between data:[] and missing data.
    // Use the authenticated SDK transport and the same request validity scope.
    final response = await _sdk.httpService.getRequest(
      '/api/v1/user/invite/details?current=1&page_size=$withdrawMinimumPaidRecords',
    );
    final data = response['data'];
    final rows = data is Map ? data['data'] : data;
    final total = data is Map ? data['total'] ?? response['total'] : response['total'];
    if ((response.containsKey('success') && response['success'] != true) ||
        rows is! List || rows.length > withdrawMinimumPaidRecords ||
        (total != null && (total is! int || total < 0 ||
            rows.length != total.clamp(0, withdrawMinimumPaidRecords)))) {
      throw const FormatException('返佣记录分页响应无效');
    }
    final ids = <int>{};
    for (final row in rows) {
      final raw = row is Map ? row['id'] : null;
      final id = raw is int ? raw : raw is String ? int.tryParse(raw) : null;
      if (id == null || id <= 0 || !ids.add(id)) {
        throw const FormatException('返佣记录缺少有效标识');
      }
    }
    return rows.length;
  });

  @override
  Future<XbResult<bool>> withdrawCommission({
    required String method,
    required String account,
  }) async =>
      // throw 形态。后端整笔提现工单制；门槛 / 收款方式白名单校验在后端（失败 → BusinessError）。
      _guard(
        'withdrawCommission',
        () => _sdk.invite.withdrawCommission(method: method, account: account),
      );

  @override
  Future<XbResult<bool>> transferCommissionToBalance(double yuan) async {
    final cents = yuan.isFinite ? parseYuanCents(yuan.toString()) : null;
    if (cents == null) {
      return const XbFailure(
        XbBusiness(BusinessErrorKind.generic, '请输入有效的划转金额，最多两位小数', null),
      );
    }
    return _guard(
      'transferCommissionToBalance',
      () => _sdk.invite.transferCommissionToBalance(cents.toDouble()),
    );
  }

  @override
  Future<XbResult<List<String>>> getWithdrawMethods() async =>
      // throw 形态。后端 /api/v1/user/comm/config 的收款方式白名单；失败 → UI 回退本地默认。
      _guard('getWithdrawMethods', () => _sdk.invite.getWithdrawMethods());

  @override
  Future<XbResult<XbShareLink>> getShareLink() async =>
      // throw 形态。免登录 guest 接口；关闭/未配置时 SDK 返 enabled=false 的 model（不抛）。
      _guard('getShareLink', () async {
        final m = await _sdk.shareLink.getShareLink();
        return XbShareLink(
          enabled: m.enabled,
          primaryUrl: m.primaryUrl,
          backupUrl: m.backupUrl,
        );
      });

  @override
  Future<XbResult<List<XbTutorial>>> getTutorials() => _getTutorials();

  @override
  Future<XbResult<List<XbTutorial>>> getTutorialsForRequest({
    required bool Function() isActive,
  }) => _getTutorials(isActive: isActive);

  Future<XbResult<List<XbTutorial>>> _getTutorials({
    bool Function()? isActive,
  }) =>
      // KnowledgeList 只拉目录；只收录两种精确分类，不回退到含正文的旧列表。
      _guard('getTutorials', () async {
        final items = await _sdk.knowledgeList.getKnowledgeList();
        return [
          for (final it in items)
            if (it.category == _kTutorialCategory || it.category == _ipTutorialCategory)
              XbTutorial(
                requiresIpPlan: it.category == _ipTutorialCategory,
                id: it.id,
                title: it.title,
                updatedAt: _epochToDate(it.updatedAt),
              ),
        ];
      }, isActive: isActive);

  @override
  Future<XbResult<XbTutorialDetail>> getTutorialDetail(int id) =>
      _getTutorialDetail(id);

  @override
  Future<XbResult<XbTutorialDetail>> getTutorialDetailForRequest(
    int id, {
    required bool Function() isActive,
  }) => _getTutorialDetail(id, isActive: isActive);

  Future<XbResult<XbTutorialDetail>> _getTutorialDetail(
    int id, {
    bool Function()? isActive,
  }) => _guard('getTutorialDetail', () async {
    var active = true;
    try {
      return await _withValidity(() => active, () async {
        final baseFuture = _readTutorialResourceBase();
        final a = await _sdk.knowledge.getKnowledgeDetail(id);
        return XbTutorialDetail(
          requiresIpPlan: a.category == _ipTutorialCategory,
          id: a.id,
          title: a.title,
          body: a.body,
          resourceBase: await baseFuture,
          updatedAt: _epochToDate(a.updatedAt),
        );
      });
    } finally {
      // A failed article must not leave its auxiliary recovery round alive.
      active = false;
    }
  }, isActive: isActive);

  @override
  Future<XbResult<List<XbNotice>>> getNotices() =>
      // 后端 /user/notice/fetch 固定返 ≤5 条；过滤 show==true（领域组装，§2.2）。
      _guard('getNotices', () async {
        final list = await _sdk.notice.getNoticesPaged(current: 1);
        return [
          for (final n in list)
            if (n.show)
              XbNotice(
                id: n.id,
                title: n.title,
                content: n.content,
                createdAt: _epochToDate(n.createdAt),
                updatedAt: n.updatedAt,
              ),
        ];
      });

  @override
  Future<String> currentUserIdHash() async {
    // 不向 UI 暴露原始 token：在反腐层内取 token → 派生 hash（公告已读本地存储 key 用）。
    try {
      return userIdHashFromToken(await _sdk.getToken());
    } catch (_) {
      return 'anon'; // storage 异常兜底（Property 1 永不抛）。
    }
  }

  // ───────── W7 SDK model → 领域模型映射 ─────────

  /// XbPlanPeriod → SDK PlanPeriod（值序一一对应：monthly..resetTraffic）。
  PlanPeriod _toSdkPeriod(XbPlanPeriod p) => PlanPeriod.values[p.index];

  /// SDK PlanPeriod → XbPlanPeriod。
  XbPlanPeriod _toXbPeriod(PlanPeriod p) => XbPlanPeriod.values[p.index];

  /// 后端 Unix 秒时间戳 → DateTime（本地时区）。0 / 缺失 → 取当前时间兜底。
  DateTime _epochToDate(int epochSeconds) => epochSeconds > 0
      ? DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000)
      : DateTime.now();

  double? _centsToYuan(double? cents) => cents == null ? null : cents / 100;

  PlanItem _mapPlan(PlanModel m) {
    final prices = <PricePlan>[];
    for (final sdkPeriod in PlanPeriod.values) {
      final yuan = m.priceForPeriod(sdkPeriod);
      if (yuan != null &&
          orderQuoteCents(yuan) != null &&
          (yuan > 0 || sdkPeriod == PlanPeriod.resetTraffic)) {
        prices.add(PricePlan(period: _toXbPeriod(sdkPeriod), amountYuan: yuan));
      }
    }
    return PlanItem(
      id: m.id,
      name: m.name,
      description: m.content,
      renewable: m.renew,
      transferEnableGb: m.transferEnable.toInt(), // 第12轮：transfer_enable 单位 GB
      prices: prices,
    );
  }

  OrderSummary _mapOrderSummary(OrderModel m) => OrderSummary(
    tradeNo: m.tradeNo ?? '',
    planName: m.orderPlan?.name,
    period: switch (PlanPeriod.fromValue(m.period)) {
      final period? => _toXbPeriod(period),
      null => null,
    },
    totalAmountYuan: m.totalAmountInYuan,
    status: _mapOrderStatus(OrderStatus.fromRaw(m.status)),
    createdAt: m.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0),
  );

  XbOrderStatus? _mapOrderStatus(OrderStatus? s) => switch (s) {
    OrderStatus.pending => XbOrderStatus.pending,
    OrderStatus.processing => XbOrderStatus.processing,
    OrderStatus.cancelled => XbOrderStatus.cancelled,
    OrderStatus.completed => XbOrderStatus.completed,
    OrderStatus.discounted => XbOrderStatus.discounted,
    null => null,
  };

  PaymentMethodItem _mapPaymentMethod(PaymentMethodModel m) {
    bool isNetworkUrl(Uri url) =>
        (url.isScheme('https') || url.isScheme('http')) &&
        url.host.isNotEmpty &&
        !url.authority.contains('@') &&
        (!url.hasPort || (url.port > 0 && url.port <= 65535));

    String? iconUrl() {
      final raw = m.icon?.trim();
      if (raw == null ||
          raw.isEmpty ||
          RegExp(r'[\x00-\x1f\x7f\\]').hasMatch(raw) ||
          RegExp(r'^\w+://[^/?#]*@').hasMatch(raw)) {
        return null;
      }
      final icon = Uri.tryParse(raw);
      if (icon == null) return null;
      if (icon.hasScheme) return isNetworkUrl(icon) ? icon.toString() : null;
      if (icon.hasAuthority ||
          icon.path.isEmpty ||
          icon.path == '/' ||
          icon.pathSegments.any(
            (segment) =>
                segment.contains('/') ||
                segment.contains('\\') ||
                RegExp(r'%[0-9a-fA-F]{2}').hasMatch(segment),
          )) {
        return null;
      }

      final base = Uri.tryParse(_sdk.baseUrl ?? '');
      if (base == null || !isNetworkUrl(base)) return null;
      final prefix = base.path.endsWith('/') ? base.path : '${base.path}/';
      final directory = Uri(
        scheme: base.scheme,
        host: base.host,
        port: base.hasPort ? base.port : null,
        path: prefix,
      );
      // A leading slash from the panel is still relative to the branded API
      // directory, unless the reference already includes that directory.
      final relative = raw.startsWith('/') && !icon.path.startsWith(prefix)
          ? raw.substring(1)
          : raw;
      final resolved = directory.resolve(relative);
      return resolved.origin == directory.origin &&
              resolved.path.startsWith(prefix) &&
              !resolved.pathSegments.any((part) => part == '.' || part == '..')
          ? resolved.toString()
          : null;
    }

    String? icon;
    try {
      icon = iconUrl();
    } on FormatException {
      // Invalid optional artwork must not fail the payment-method response.
    }
    return PaymentMethodItem(
      id: m.id,
      name: m.name,
      icon: icon,
      paymentMethod: m.paymentMethod,
      feeFixedYuan: _centsToYuan(m.handlingFeeFixed), // cents/100（第12轮）
      feePercent: m.handlingFeePercent, // 百分比原值
    );
  }

  /// SDK CheckoutOutcome sealed 5 分支 → UI 副本（零 SDK 类型穿透 Property 2）。
  ui.CheckoutOutcomeUi _mapCheckout(CheckoutOutcome o) => switch (o) {
    CheckoutRedirect(:final url) => ui.CheckoutRedirect(url),
    CheckoutQrCode(:final qrCodeUrl) => ui.CheckoutQrCode(qrCodeUrl),
    CheckoutPaid() => const ui.CheckoutPaid(),
    CheckoutCanceled(:final message) => ui.CheckoutCanceled(message),
    CheckoutFailed(:final message) => ui.CheckoutFailed(message),
  };
}
