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

  /// 发起登录 / 注册（→ authenticating）。
  void startAuthenticating() => state = AuthState.authenticating;

  /// 认证成功（→ authenticated）。
  void markAuthenticated() => state = AuthState.authenticated;

  /// 未登录 / 登录失败 / 登出（→ unauthenticated）。
  ///
  /// 401 尾递归保护：已是 unauthenticated 时再调是 no-op（idempotent）。
  void markUnauthenticated() {
    if (state == AuthState.unauthenticated) return; // R12 跳登录只触发一次
    state = AuthState.unauthenticated;
  }
}
