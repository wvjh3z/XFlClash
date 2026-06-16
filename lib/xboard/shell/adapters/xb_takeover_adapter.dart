/// 形态 A「网络接管方式」适配器（桌面专属，spec `xboard-form-a-ui-revamp`）。
///
/// **职责（适配层铁律收口）**：形态 A 桌面首页的「系统代理 / 虚拟网卡(TUN)」两个独立开关，
/// 读写 FlClash 内部 provider —— Tab/widget 不直接 import FlClash provider，全经本适配器：
/// - 系统代理：`networkSettingProvider.systemProxy`（给操作系统设 HTTP/SOCKS 代理）。
/// - 虚拟网卡：`patchClashConfigProvider.tun.enable`（建虚拟网卡，IP 层接管全部流量）。
///
/// 两者**互不互斥**（与上游 FlClash dashboard 一致），可同时开启、互补接管。
/// 仅桌面使用（移动端走 VPN，不暴露此卡）。
library;

import 'package:fl_clash/providers/config.dart' show networkSettingProvider;
import 'package:fl_clash/providers/providers.dart' show patchClashConfigProvider;
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 网络接管方式适配器。
class XbTakeoverAdapter {
  const XbTakeoverAdapter();

  /// 系统代理是否开启。
  bool systemProxyEnabled(WidgetRef ref) =>
      ref.watch(networkSettingProvider.select((s) => s.systemProxy));

  /// 设置系统代理开关。
  void setSystemProxy(WidgetRef ref, bool value) {
    ref
        .read(networkSettingProvider.notifier)
        .update((state) => state.copyWith(systemProxy: value));
  }

  /// 虚拟网卡（TUN）是否开启。
  bool tunEnabled(WidgetRef ref) =>
      ref.watch(patchClashConfigProvider.select((s) => s.tun.enable));

  /// 设置虚拟网卡（TUN）开关。
  void setTun(WidgetRef ref, bool value) {
    ref
        .read(patchClashConfigProvider.notifier)
        .update((state) => state.copyWith.tun(enable: value));
  }
}

/// 接管方式适配器单例 provider（Tab 经此取，测试可 override）。
final xbTakeoverAdapterProvider = Provider<XbTakeoverAdapter>(
  (ref) => const XbTakeoverAdapter(),
);
