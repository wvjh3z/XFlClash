/// Xboard 模块入口（conventions §1.1 / §1.4 / design「lib/xboard/ 目录结构」）。
///
/// **唯一被 FlClash 既有代码引用的入口**（接缝点 #1：`main.dart` 在 HttpOverrides 后 /
/// runApp 前调 `XboardModule.bootstrap(container)`，外层包 try/catch 隔离故障 DD-2.bis）。
///
/// **职责**：
/// - `bootstrap(container)`：同步阶段（DD-17 render-first，零网络）—— 加载 flavor /
///   早期 Sentry hook / 本地 fallback 解密 / SDK initialize / 写基础设施 provider；
///   异步阶段（runApp 后）—— 远端 Bootstrap 拉取 + endpoint 竞速 + globalUa 注入（W5）。
/// - `dispose()`：释放长生命周期资源（observer / timer / 订阅 / race controller，DD-19）。
///
/// **生命周期归属（DD-19）**：FlClash 根 ProviderContainer 全 App 不 dispose；bootstrap 是
/// runApp 前 fire-and-forget，不挂 widget 生命周期，故本模块持有并负责 dispose 自起资源。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Xboard 模块的启动 / 释放入口。
class XboardModule {
  XboardModule._();

  /// 同步阶段启动（接缝点 #1 调用点）。
  ///
  /// W1.5 填实 step 0-8；当前为骨架占位（W1.1）。
  /// **绝不抛**：所有内部异常在此全捕获，避免波及 FlClash 启动（DD-2 / NFR-7）。
  static Future<void> bootstrap(ProviderContainer container) async {
    // W1.5 实现：firstLaunch 检测 / flavor 绑定 / Sentry 早期 hook /
    // 本地 fallback 解密 / SDK initialize / 写基础设施 provider。
  }

  /// 释放模块自起的长生命周期资源（DD-19）。
  static Future<void> dispose() async {
    // W5 填实：移除 lifecycle observer / 取消心跳 timer / 关 connectivity 订阅 /
    // dispose EndpointRaceController。
  }
}
