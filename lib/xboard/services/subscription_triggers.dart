/// R4.6 step2b 订阅刷新触发统一入口（T1-T4 + onResume + 账号信息刷新）。
///
/// **为什么收口在一处**：订阅 YAML 刷新（`subscriptionServiceProvider.sync`）与账号信息刷新
/// （invalidate `userProfileProvider`）是两条独立链路，但触发时机几乎重合（登录/购买/手动/onResume）。
/// 各调用点（login/order/account card/lifecycle）只调本类语义方法，不各自拼装两条链路 + gate。
///
/// **gate（永不在未就绪时调反腐层）**：所有方法先查 `bootstrapReadyProvider`（SDK 已 init）+
/// `authStateProvider == authenticated`（F14：游客不触发，避免 R10 误弹）。不满足 → no-op。
///
/// **fire-and-forget**（Property 1）：订阅 sync 是后台静默（§A），调用点不 await、不阻塞 UI；
/// sync 自身 single-flight + force 队列 + 永不抛。账号刷新走 `ref.invalidate`（同步触发重拉）。
///
/// **24h 节流**（onResume 专用，θ-7 单调时钟 `Stopwatch` 防改钟）：onResume 高频（每次切前台），
/// 节流避免频繁拉订阅打爆后端；登录/购买/手动是「数据已变」语义，不节流。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/auth_state_provider.dart';
import '../providers/user_profile_provider.dart';
import '../providers/xboard_providers.dart';

/// onResume 订阅刷新节流窗口（24h，用户 2026-06-02 决策）。
const Duration kSubscriptionResumeThrottle = Duration(hours: 24);

class SubscriptionTriggers {
  SubscriptionTriggers._();

  /// onResume 节流单调时钟（θ-7：距上次成功刷新 ≥24h 才真拉；防改系统时间绕过）。
  /// null = 从未刷新过（首次 onResume 直接放行）。
  static Stopwatch? _resumeThrottle;

  /// 是否已就绪（SDK init + 已登录）—— 所有触发的统一 gate（F14）。
  static bool _ready(WidgetRef ref) =>
      ref.read(bootstrapReadyProvider) &&
      ref.read(authStateProvider) == AuthState.authenticated;

  /// 触发订阅 YAML 同步（fire-and-forget，永不抛）。未就绪 no-op。
  static void _fireSync(WidgetRef ref, {required bool force}) {
    if (!_ready(ref)) return;
    try {
      // ignore: discarded_futures  (后台静默，§A 不 await)
      ref.read(subscriptionServiceProvider).sync(force: force);
    } catch (_) {
      // provider 未就绪（tokenStorage 未注入等）→ 静默（Property 1）。
    }
  }

  /// 刷新账号信息（invalidate userProfileProvider，触发重拉）。未就绪 no-op。
  static void _refreshAccount(WidgetRef ref) {
    if (!_ready(ref)) return;
    ref.invalidate(userProfileProvider);
  }

  /// T1 登录成功 / T2 已登录冷启动：force 同步订阅 + 刷新账号信息。
  static void onAuthenticated(WidgetRef ref) {
    _fireSync(ref, force: true);
    _refreshAccount(ref);
  }

  /// T3 订单完成（支付成功 / 终态 completed/discounted）：force 同步订阅 + 刷新账号信息。
  static void onOrderCompleted(WidgetRef ref) {
    _fireSync(ref, force: true);
    _refreshAccount(ref);
  }

  /// T4 用户主动刷新（账号卡刷新按钮 / 下拉）：force 同步订阅 + 刷新账号信息。
  static void onManualRefresh(WidgetRef ref) {
    _fireSync(ref, force: true);
    _refreshAccount(ref);
  }

  /// onResume（切前台）：24h 节流——距上次成功刷新 ≥24h 才真拉订阅 + 刷新账号信息。
  /// 节流未到 → no-op（不打爆后端）。force=false（非「数据已变」语义）。
  static void onResume(WidgetRef ref) {
    if (!_ready(ref)) return;
    final sw = _resumeThrottle;
    if (sw != null && sw.elapsed < kSubscriptionResumeThrottle) {
      return; // 节流窗口内，跳过。
    }
    _resumeThrottle = Stopwatch()..start();
    _fireSync(ref, force: false);
    _refreshAccount(ref);
  }

  /// 测试可见：重置节流时钟（teardown 用，避免跨用例污染）。
  static void debugResetThrottle() => _resumeThrottle = null;
}
