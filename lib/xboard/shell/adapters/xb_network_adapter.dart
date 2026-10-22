/// 形态 A 网络检测适配器（出口 IP，spec `xboard-form-a-ui-revamp` / W3）。
///
/// 复用 v0.9.1 的 outboundIpProbeProvider，以 routedOutbound 标识当前路由出口。
/// provider 生命周期内登记 watch/unwatch；刷新沿用底座的探测世代与旧结果隔离，
/// 页面只消费 XbIpStatus，不自行请求第三方 IP 接口。
library;

import 'package:fl_clash/providers/outbound_ip.dart';
import 'package:fl_clash/providers/routed_probe.dart';
import 'package:fl_clash/common/service_probe.dart' show routedOutbound;
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 出口 IP 状态（轻量投影，primitive only）。
class XbIpStatus {
  const XbIpStatus({required this.loading, this.ip, this.countryCode});

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

  /// 投影当前路由出口的 IP 探测状态。
  XbIpStatus ipStatus(WidgetRef ref) {
    final s = ref.watch(outboundIpProbeProvider).entryOf(routedOutbound);
    return XbIpStatus(
      loading: s.isLoading || s.phase == ProbePhase.empty,
      ip: s.value?.ip,
      countryCode: s.value?.countryCode,
    );
  }

  /// 主动触发一次出口 IP 检测（首页初始化 / 连接 / 切换节点后调用）。
  /// 通过底座 route-aware probe 刷新，保留其请求合并与过期结果处理。
  void startCheck(WidgetRef ref) {
    ref.read(outboundIpProbeProvider.notifier).refresh(const [routedOutbound]);
  }

  /// 强制重新检测（IP 卡刷新按钮用）。
  ///
  /// 与主动检测共用底座 refresh；不再销毁 provider 或重建探测所有者。
  void forceCheck(WidgetRef ref) {
    // The route-aware probe supersedes stale results without replacing its owner.
    ref.read(outboundIpProbeProvider.notifier).refresh(const [routedOutbound]);
  }
}

/// 网络检测适配器单例 provider（Tab 经此取，测试可 override）。
final xbNetworkAdapterProvider = Provider<XbNetworkAdapter>((ref) {
  final probe = ref.read(outboundIpProbeProvider.notifier);
  probe.watch(routedOutbound);
  ref.onDispose(() => probe.unwatch(routedOutbound));
  return const XbNetworkAdapter();
});
