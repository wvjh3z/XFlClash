/// 形态 A 验证码冷却守卫 mixin（行为层抽象）。
///
/// **背景（批次二反思）**：`setState(_cooldown=60) → Timer.periodic(1s, 递减→0 取消)` +
/// `dispose 里 _timer?.cancel()` + 「发送失败重置冷却」这套倒计时在 register_sheet / forgot_pwd_sheet
/// 逐字重复。手写 timer 易漏 `mounted` 判定（dispose 后 setState 报错）、漏 cancel（泄漏 / 双 timer
/// 叠加递减），且「发送失败立即解锁」逻辑各写一遍易飘。本 mixin 收口，**保证行为正确**。
///
/// **契约（必须满足，已被 xb_cooldown_guard_test 锁定）**：
/// 1. 倒计时：[startCooldown] 后 `cooldownSeconds` 从 n 每秒 -1 到 0 自动停。
/// 2. 重入安全：冷却中再调 [startCooldown] → 取消旧 timer 重新计时（不叠加双 timer）。
/// 3. 立即解锁：[resetCooldown] 取消 timer 并归零（发送失败时用，避免无谓锁 60s）。
/// 4. mounted 安全：State 已 dispose → timer 回调不 setState（不报错）。
/// 5. 自动清理：[dispose] 自动 cancel timer（混入方 super.dispose 即可，无需手动 cancel）。
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

/// 给 [State] 混入「验证码冷却倒计时」。用 `cooldownSeconds` 驱动 UI（>0 禁用 + 显示秒数）。
mixin XbCooldownGuard<T extends StatefulWidget> on State<T> {
  int _cooldown = 0;
  Timer? _timer;

  /// 冷却剩余秒（>0 时按钮应禁用 + 显示倒计时）。
  int get cooldownSeconds => _cooldown;

  /// 是否冷却中。
  bool get cooling => _cooldown > 0;

  /// 启动冷却倒计时（默认 60s）。冷却中再调会取消旧 timer 重新计时（不叠加）。
  void startCooldown([int seconds = 60]) {
    _timer?.cancel();
    if (!mounted) return;
    setState(() => _cooldown = seconds);
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() => _cooldown--);
      if (_cooldown <= 0) t.cancel();
    });
  }

  /// 立即解锁：取消 timer 并归零（发送失败时调用，让用户可立即重发）。
  void resetCooldown() {
    _timer?.cancel();
    if (!mounted) return;
    setState(() => _cooldown = 0);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
