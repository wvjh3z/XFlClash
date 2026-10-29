/// 形态 A 网络检测适配器（出口 IP，spec `xboard-form-a-ui-revamp` / W3）。
///
/// 首页使用旧版七源 Dart 竞速；宿主路由变化只负责触发刷新，不等待 Core IP 探测。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/exit_ip_provider.dart';

/// 出口 IP 状态（轻量投影，primitive only）。
class XbIpStatus {
  const XbIpStatus({
    required this.loading,
    this.ip,
    this.countryCode,
    this.failed = false,
  });

  /// 检测中（首测 / 重测进行中）。
  final bool loading;

  /// Last lookup failed; a retained IP is historical, not a fresh success.
  final bool failed;

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

  /// 投影当前路由出口的 IP 探测状态。
  XbIpStatus ipStatus(WidgetRef ref) {
    final s = ref.watch(xbExitIpProvider);
    return XbIpStatus(
      loading: s.loading,
      ip: s.result?.ip,
      countryCode: s.result?.countryCode,
      failed: s.failed,
    );
  }

  /// 强制重新检测（IP 卡刷新按钮用）。
  ///
  /// 立即清空旧值并重测，不销毁 provider。
  void forceCheck(WidgetRef ref) {
    ref.read(xbExitIpProvider.notifier).refresh(immediate: true);
  }
}

/// 网络检测适配器单例 provider（Tab 经此取，测试可 override）。
final xbNetworkAdapterProvider = Provider<XbNetworkAdapter>(
  (ref) => const XbNetworkAdapter(),
);
