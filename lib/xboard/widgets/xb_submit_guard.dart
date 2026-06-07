/// 形态 A 提交态守卫 mixin（行为层抽象）。
///
/// **背景（批次二反思）**：`setState(busy=true) → try{...} finally{ if(mounted) setState(busy=false) }`
/// 这套提交守卫在 6 处重复手写（order_payment 的 _pay/_cancel/_reloadMethods、plan_detail 的
/// _checkCoupon/_submitOrder、pending_order 的 _doCancel）。手写易漏 `finally` 或忘 `mounted`
/// 判定 → busy 永久卡死（同账号卡横幅卡死的同类病）。本 mixin 收口，**保证行为正确**。
///
/// **契约（必须满足，已被 xb_submit_guard_test 锁定）**：
/// 1. 永远终止：action 成功 / 返回失败 / **抛异常** 三种情况，`submitting` 都复位为 false。
/// 2. 重入安全：in-flight 期间再调 [runSubmit] 直接忽略（不重复发起、不抛）。
/// 3. mounted 安全：State 已 dispose → 不 setState（不报错）。
/// 4. 不吞异常语义：action 抛出的异常**会重新抛给调用方**（调用方可按需 try/catch 落地文案），
///    但无论是否抛，`submitting` 都已复位（finally 保证）。
library;

import 'package:flutter/widgets.dart';

/// 给 [State] 混入「提交态守卫」。用 `submitting` 驱动 UI loading，用 [runSubmit] 包提交动作。
mixin XbSubmitGuard<T extends StatefulWidget> on State<T> {
  bool _submitting = false;

  /// 是否正在提交（驱动按钮 loading / 禁用）。
  bool get submitting => _submitting;

  /// 包裹一次异步提交：置 `submitting=true` → 跑 [action] → 无论成败/异常都复位。
  ///
  /// 重入：已在提交中 → 直接返回（忽略本次）。返回 action 的结果（若有）。
  /// 异常：action 抛出会 rethrow（调用方可 catch 落地），但 `submitting` 已在 finally 复位。
  Future<R?> runSubmit<R>(Future<R> Function() action) async {
    if (_submitting) return null;
    if (mounted) setState(() => _submitting = true);
    try {
      return await action();
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }
}
