/// 登录态状态机（R4 / DD-19 / 数据一致性 § G）。
///
/// **3 态枚举（§ G ε7）**：`unauthenticated` / `authenticating` / `authenticated`。
/// transition：
/// - login/register 发起 → authenticating
/// - SDK 返 Success → authenticated
/// - SDK 返 Failure（密码错/限流/网络）→ unauthenticated
/// - 401/403 双重判定（R4.4 自动登出）/ R4.5 主动登出 → unauthenticated
/// - R7 sync 进行中**不进 refreshing 子态**（后台静默，UI 各页面 loading 体现，§ G）
///
/// **401 尾递归保护**：切 unauthenticated 后再次切是 no-op（idempotent），UI R12 跳登录只触发一次。
///
/// **首帧登录态判定（已知风险表 SDK initialize 注）**：反腐层用 `authStateStream` 首帧 /
/// `SecureStorageTokenStorage.readToken()` 直读判定，**不**同步读 `XBoardSDK.isAuthenticated`
/// （init 返回后同步读有竞态——有 token 却短暂判未登录；SDK v1.15.0 已 await ready 缓解，仍推荐首帧）。
library;

import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../services/sentry_bootstrap.dart';
import '../services/subscription_triggers.dart';
import 'user_profile_provider.dart';
import 'xboard_providers.dart';

part '../generated/providers/auth_state_provider.g.dart';

/// 登录态 3 态（§ G）。
enum AuthState {
  /// 未登录（游客可继续用 FlClash 默认功能，R4.3/D6）。
  unauthenticated,

  /// 登录 / 注册请求中（R1.7/R2.7 按钮 disabled + spinner）。
  authenticating,

  /// 已登录。
  authenticated,
}

/// 登录态 provider（keepAlive，DD-19）。
///
/// **W3.2 不在 W1.6 基础设施集**：单独建避免 codegen 同名冲突（design §I 注）。
@Riverpod(keepAlive: true)
class AuthStateNotifier extends _$AuthStateNotifier {
  @override
  AuthState build() => AuthState.unauthenticated;

  /// 状态切换 + DD-23 auth.state tag（W5.7 / 5.7.2）。
  void _set(AuthState next) {
    state = next;
    SentryBootstrap.tagAuthState(next.name);
  }

  /// 发起登录 / 注册（→ authenticating）。
  void startAuthenticating() => _set(AuthState.authenticating);

  /// 认证成功（→ authenticated）。
  void markAuthenticated() => _set(AuthState.authenticated);

  /// 未登录 / 登录失败 / 登出（→ unauthenticated）。
  ///
  /// 401 尾递归保护：已是 unauthenticated 时再调是 no-op（idempotent）。
  void markUnauthenticated() {
    if (state == AuthState.unauthenticated) return; // R12 跳登录只触发一次
    _set(AuthState.unauthenticated);
  }

  /// R4.5 主动登出编排（数据一致性总章 § B step 4-6 + idempotency）。
  ///
  /// **清理顺序**（§ B）：
  /// 1. step 4：删 file profile「我的套餐」+ 外挂索引（`clearForCurrentUser`，**必须在清 token
  ///    前**——它用当前 token 算 userIdHash 定位 profile；清 token 后 hash 变 null 找不到，
  ///    会残留上个账号配置 = 多租户泄漏）。
  /// 2. step 0+2+5：反腐层 `logout()`（服务端撤销 + 清订阅缓存 + 清 token）。
  /// 3. 清账号信息内存缓存（invalidate `userProfileProvider`，避免下个用户短暂看到上个账号数据）。
  /// 4. step 6：切 `unauthenticated`（触发 R12 重定向）。
  ///
  /// **idempotent + 永不抛**：每步独立 try/catch（Property 1）；无论成败都切 unauthenticated
  /// （本地态以"已登出"为终态，避免卡中间态）；重入安全（markUnauthenticated 幂等）。
  Future<void> logout() async {
    // step 4（先于清 token）：删 file profile + 外挂索引。永不抛。
    try {
      await ref.read(subscriptionServiceProvider).clearForCurrentUser();
    } catch (_) {
      // profile/索引清理失败不阻塞登出（最大努力，§ B 每步独立）。
    }
    // step 0+2+5：反腐层 logout（服务端撤销 + 清订阅缓存 + 清 token）。永不抛。
    await ref.read(xboardServiceProvider).logout();
    // 清账号信息内存缓存（keepAlive provider 不会自动失效）。
    ref.invalidate(userProfileProvider);
    // 重建订阅服务（keepAlive 单例 _loggingOut 已置 true，invalidate 让下次登录得新实例，
    // 避免 _loggingOut 残留永久禁用 sync）。
    ref.invalidate(subscriptionServiceProvider);
    // 重置 onResume 24h 节流时钟（下个账号首次 onResume 不被上个账号的节流挡住）。
    SubscriptionTriggers.resetResumeThrottle();
    // step 6：切未登录态。
    _set(AuthState.unauthenticated);
  }

  /// R4.4 401/403 自动登出（D61 双重判定 / W3.7）。
  ///
  /// 任意需登录 API 返 `XbUnauthorized`（SDK `AuthInterceptor` 已对 401 / 403+5 子串
  /// 主动 clearToken）时调用。**不调服务端撤销**（已经 401，token 已失效，调也无意义）+
  /// **不重复清 token**（SDK 已清），仅切 `unauthenticated` 触发 R12 跳登录。
  ///
  /// 幂等：已 unauthenticated 时 no-op（401 风暴只触发一次重定向，复用 markUnauthenticated 守卫）。
  void handleUnauthorized() => markUnauthenticated();
}
