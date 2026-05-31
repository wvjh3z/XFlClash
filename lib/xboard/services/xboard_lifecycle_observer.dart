/// Xboard 生命周期观察者（决策 #14 / ζ2 平台分级 / DD-19 dispose 顺序）。
///
/// **自挂**（决策 #14）：`implements WidgetsBindingObserver`，**不**复用 FlClash app_manager 的
/// observer（多 observer broadcast 互不覆盖，DD-19）；日志加 `[XboardLifecycle]` 前缀区分来源。
///
/// **ζ2 平台分级**（design 跨平台矩阵 § B）：
/// - `paused`：移动端（Android）暂停心跳/QR/processing Timer（电池）；desktop 保持运行。
/// - `resumed`：移动端重启 Timer；**4 平台都**触发 `refreshRaceInBackground`（R15.C.20）。
///
/// **dispose 顺序**（DD-19）：removeObserver → cancel 订阅 → cancel timer → race dispose
/// （避免 Timer 最后一拍撞 disposed 依赖）。
library;

import 'dart:io' show Platform;

import 'package:flutter/widgets.dart';

import 'endpoint_race_controller.dart';

class XboardLifecycleObserver with WidgetsBindingObserver {
  XboardLifecycleObserver({
    required EndpointRaceController raceController,
    this.onPauseTimers,
    this.onResumeTimers,
    bool? isMobileOverride,
  })  : _race = raceController,
        _isMobile = isMobileOverride ?? (Platform.isAndroid || Platform.isIOS);

  final EndpointRaceController _race;

  /// 移动端 paused 时暂停 Timer（心跳/QR/processing）的回调（W6 接入具体 timer）。
  final VoidCallback? onPauseTimers;

  /// 移动端 resumed 时重启 Timer 的回调。
  final VoidCallback? onResumeTimers;

  final bool _isMobile;
  bool _attached = false;

  /// 挂到 WidgetsBinding（bootstrap step 7）。
  void attach() {
    if (_attached) return;
    WidgetsBinding.instance.addObserver(this);
    _attached = true;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
        if (_isMobile) {
          debugPrint('[XboardLifecycle] paused (mobile) → 暂停 Timer');
          onPauseTimers?.call();
        } else {
          debugPrint('[XboardLifecycle] paused (desktop) → Timer 保持运行');
        }
      case AppLifecycleState.resumed:
        if (_isMobile) {
          debugPrint('[XboardLifecycle] resumed (mobile) → 重启 Timer');
          onResumeTimers?.call();
        }
        // 4 平台都后台竞速（R15.C.20）。
        _race.refreshRaceInBackground();
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        break;
    }
  }

  /// DD-19 dispose 顺序：先摘 observer（停止接收事件），调用方随后 cancel timer / race dispose。
  void dispose() {
    if (_attached) {
      WidgetsBinding.instance.removeObserver(this);
      _attached = false;
    }
  }
}
