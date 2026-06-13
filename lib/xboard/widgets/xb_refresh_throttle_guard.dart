/// 形态 A「刷新节流」守卫 mixin（行为层抽象，§1.5 单一来源 / §11.4 防复制）。
///
/// **背景**：「点刷新 → 60s 内禁用 + 倒计时 + 冷却内再点弹提示」这套节流在
/// `nodes_tab`（刷新节点）与 `mine_tab`（刷新信息）**逐字重复**了一份
/// （`Stopwatch _throttle` + `Timer _ticker` + `_cooldownSec` + `_remainingSec` +
/// `_startCooldownTicker` + `dispose` cancel）。手写易漏 `mounted` / 漏 cancel /
/// 双 timer 叠加。本 mixin 收口，保证行为正确、单一来源。
///
/// **与 [XbCooldownGuard] 的区别（为何两个）**：
/// - [XbCooldownGuard]：`setState` 倒计时变体，从 N 递减，支持 [XbCooldownGuard.resetCooldown]
///   「发送失败立即解锁」——**验证码场景**（register / forgot sheet）。
/// - 本 mixin：**单调时钟（Stopwatch）节流**，防用户改系统时钟绕过冷却——**刷新节流场景**。
///   不支持中途 reset（节流本就该按真实时间走）。
///
/// **契约**：
/// 1. [startThrottle] 后开始计时；`cooldownSeconds` 从 [throttleSeconds] 每秒 -1 到 0 自动停。
/// 2. `throttled` 反映**实时**剩余（读 Stopwatch，不依赖 ticker 帧）：冷却内为 true。
/// 3. 重入安全：冷却中再 [startThrottle] → 取消旧 ticker 重新计时。
/// 4. mounted 安全 + 自动清理：State dispose 自动 cancel ticker（混入方 super.dispose 即可）。
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

mixin XbRefreshThrottleGuard<T extends StatefulWidget> on State<T> {
  /// 节流窗口秒数（默认 60s；混入方可 override）。
  int get throttleSeconds => 60;

  Stopwatch? _throttleSw;
  Timer? _ticker;
  int _cooldownSec = 0;

  /// 冷却剩余秒（实时，读单调时钟）。0 = 可再次操作。
  int get _remaining {
    final sw = _throttleSw;
    if (sw == null) return 0;
    final remain = throttleSeconds - sw.elapsed.inSeconds;
    return remain > 0 ? remain : 0;
  }

  /// 是否处于冷却中（实时判定，gate 用）。
  bool get throttled => _remaining > 0;

  /// 冷却剩余秒（由 ticker 每秒驱动，UI 显示用：按钮灰 + 倒计时）。
  int get cooldownSeconds => _cooldownSec;

  /// 启动节流：完成一次操作后调用，开始 [throttleSeconds] 秒冷却 + 倒计时 ticker。
  void startThrottle() {
    _throttleSw = Stopwatch()..start();
    _startTicker();
  }

  void _startTicker() {
    _ticker?.cancel();
    _cooldownSec = _remaining;
    if (_cooldownSec <= 0) return;
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      final r = _remaining;
      if (r != _cooldownSec && mounted) setState(() => _cooldownSec = r);
      if (r <= 0) _ticker?.cancel();
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }
}
