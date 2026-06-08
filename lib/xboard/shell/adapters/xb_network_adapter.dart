/// 形态 A 网络检测适配器（出口 IP，spec `xboard-form-a-ui-revamp` / W3）。
///
/// **直接复用 FlClash `networkDetectionProvider`**（已封装多源并发竞速：ipapi.co / ip-api.com /
/// ipinfo.io，谁先成功用谁 + 超时显示 + cancel 会话管理）。本适配器只做收口（适配层铁律：Tab
/// 不直接 import FlClash provider），投影为轻量 [XbIpStatus]。
///
/// **触发机制**：FlClash 在连接/切换/重置连接时 `checkIpNum+1` → `app_manager` 监听触发
/// `startCheck()`。但该监听依赖「仪表盘启用 networkDetection widget」，形态 A 不挂 FlClash 仪表盘，
/// 故由本适配器 [startCheck] 在首页初始化 / 连接 / 切换节点时**主动触发**，确保检测发生。
library;

import 'package:fl_clash/providers/app.dart' show networkDetectionProvider;
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 出口 IP 状态（轻量投影，primitive only）。
class XbIpStatus {
  const XbIpStatus({
    required this.loading,
    this.ip,
    this.countryCode,
  });

  /// 检测中（首测 / 重测进行中）。
  final bool loading;

  /// 出口 IP（null = 未知 / 超时）。
  final String? ip;

  /// 出口国家码（如 'HK'/'CN'，null = 未知）。
  final String? countryCode;

  /// 是否有有效 IP。
  bool get hasIp => ip != null && ip!.isNotEmpty;
}

/// 网络检测适配器。
class XbNetworkAdapter {
  const XbNetworkAdapter();

  /// 投影出口 IP 状态（复用 FlClash networkDetectionProvider）。
  XbIpStatus ipStatus(WidgetRef ref) {
    final s = ref.watch(networkDetectionProvider);
    return XbIpStatus(
      loading: s.isLoading,
      ip: s.ipInfo?.ip,
      countryCode: s.ipInfo?.countryCode,
    );
  }

  /// 主动触发一次出口 IP 检测（首页初始化 / 连接 / 切换节点后调用）。
  /// 复用 FlClash `startCheck`（内部 debounce + 多源竞速 + 会话取消，去重安全）。
  void startCheck(WidgetRef ref) {
    ref.read(networkDetectionProvider.notifier).startCheck();
  }
}

/// 网络检测适配器单例 provider（Tab 经此取，测试可 override）。
final xbNetworkAdapterProvider = Provider<XbNetworkAdapter>(
  (ref) => const XbNetworkAdapter(),
);
