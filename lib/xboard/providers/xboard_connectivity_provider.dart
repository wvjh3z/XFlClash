/// Xboard 网络连接状态（DD-5 单一数据源 / F23 / design 状态管理表）。
///
/// **为什么自起**（F23）：FlClash 无 Riverpod connectivity provider（其网络检测在别处），
/// Xboard 模块需独立的 connectivity 流驱动「首次离线提示页（§F）」+「离线 banner（R11.4）」。
///
/// **类型**：`StreamProvider<List<ConnectivityResult>>`（connectivity_plus ^7 返 List，
/// ζ9 跨平台一致：`r.contains(ConnectivityResult.none)` 4 平台一致表示无网络）。
///
/// **W4 范围**：建立 provider + `isOfflineProvider` 派生 + 首帧当前值。W5.4 扩展
/// lifecycle 联动（移动端后台暂停订阅）+ 与 bootstrap 异步阶段 endpoint 竞速协同。
///
/// **测试**：override 为固定值或 `fake_connectivity.dart` 的可控流，**不**裸 listen 真实硬件。
library;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

export 'package:connectivity_plus/connectivity_plus.dart' show ConnectivityResult;

part '../generated/providers/xboard_connectivity_provider.g.dart';

/// 网络连接状态流（首帧 `checkConnectivity()` 当前值 + 后续 `onConnectivityChanged`）。
///
/// keepAlive：与 App 同寿（连接状态全局共享，避免每个 widget 各自订阅）。
@Riverpod(keepAlive: true)
Stream<List<ConnectivityResult>> xboardConnectivity(Ref ref) async* {
  final connectivity = Connectivity();
  // 首帧：当前连接状态（避免 stream 首次事件前 UI 无数据）。
  try {
    yield await connectivity.checkConnectivity();
  } catch (_) {
    yield const [ConnectivityResult.none];
  }
  yield* connectivity.onConnectivityChanged;
}

/// 是否离线（派生）—— `none` 在结果集中即视为离线（ζ9 跨平台一致）。
///
/// 未就绪 / 错误时**不**判离线（保守：避免误弹离线页），返 false。
@Riverpod(keepAlive: true)
bool isOffline(Ref ref) {
  final conn = ref.watch(xboardConnectivityProvider);
  return conn.maybeWhen(
    data: (results) => results.contains(ConnectivityResult.none),
    orElse: () => false,
  );
}
