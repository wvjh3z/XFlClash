/// 形态 A 连接适配器（spec `xboard-form-a-ui-revamp` / W2.1 / R2.1·R2.2）。
///
/// **职责（风险②b 收口）**：把 FlClash 内部「连接态 + 连接控制」收口成形态 A 的 4 态视图 +
/// toggle 操作。Tab 只认本适配器，**不**直接 import FlClash internal provider —— 这是
/// 适配层铁律的落地点（`adapters/` 是唯一允许 import FlClash 内部符号的地方）。
///
/// **4 态合成（design 风险②「连接中态」坑）**：单看 `isStartProvider`(bool) 不够表达
/// 「连接中」过渡态，必须叠加 `coreStatusProvider`：
/// - `!bootstrapReady` → booting（启动中，连接操作禁用）
/// - `coreStatus == connecting` → connecting（转圈）
/// - `isStart`（runTime != null）→ connected
/// - 否则 → disconnected
///
/// **toggle**：→ `setupActionProvider.updateStatus`（与 `StartButton.handleSwitchStart` 同源，
/// 写同一份内核状态，Property 4 无影子状态）。
library;

import 'package:fl_clash/enum/enum.dart' show CoreStatus;
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 形态 A 连接 4 态（外形层只认本枚举，不碰 FlClash CoreStatus/isStart）。
enum XbConnState {
  /// 启动中（bootstrap 未就绪）：连接操作禁用（R2.5 / R2.1）。
  booting,

  /// 未连接。
  disconnected,

  /// 连接中（过渡态，转圈，R2.4）。
  connecting,

  /// 已连接。
  connected,
}

/// 连接适配器：合成 4 态 + toggle。
///
/// 设计为无状态工具（方法接 `ref`/`WidgetRef`），便于 Tab 直接调用 + 测试注入 override。
class XbConnectAdapter {
  const XbConnectAdapter();

  /// 合成连接 4 态（design 风险②：isStart 叠加 coreStatus）。
  ///
  /// 用 `ref.watch` 子粒度订阅：bootstrapReady / coreStatus / isStart 任一变即重算。
  XbConnState connState(WidgetRef ref) {
    final ready = ref.watch(bootstrapReadyProvider);
    if (!ready) return XbConnState.booting;

    final coreStatus = ref.watch(coreStatusProvider);
    if (coreStatus == CoreStatus.connecting) return XbConnState.connecting;

    final started = ref.watch(isStartProvider);
    return started ? XbConnState.connected : XbConnState.disconnected;
  }

  /// 当前是否「已连接」（便捷判断，等价 connState==connected）。
  bool isConnected(WidgetRef ref) => connState(ref) == XbConnState.connected;

  /// VPN 是否处于「应开启」意图（runTime 已置位）。
  ///
  /// 用于区分「用户/系统让 VPN 开着」(true) 与「冷启动核心预热」(false)：后者 `coreStatus`
  /// 也会短暂为 connecting，但 `isStart` 为 false → 外形层据此把预热判为「准备中」而非「连接中」。
  bool startIntended(WidgetRef ref) => ref.watch(isStartProvider);

  /// 连接操作是否可用（booting 态禁用，R2.5）。
  bool canToggle(WidgetRef ref) => connState(ref) != XbConnState.booting;

  /// 切换连接状态（连/断）。
  ///
  /// → `setupActionProvider.updateStatus(target)`：与 FlClash `StartButton` 同源写内核
  /// （Property 4 无影子状态）。booting 态忽略（gate canToggle）。
  Future<void> toggle(WidgetRef ref) async {
    if (!canToggle(ref)) return;
    final started = ref.read(isStartProvider);
    await ref.read(setupActionProvider.notifier).updateStatus(!started);
  }

  /// 显式设连接态（供线路卡 / 横幅等场景，幂等）。
  Future<void> setStatus(WidgetRef ref, {required bool start}) async {
    if (!canToggle(ref)) return;
    await ref.read(setupActionProvider.notifier).updateStatus(start);
  }
}

/// 连接适配器单例 provider（Tab 经此取，测试可 override 注入 fake）。
final xbConnectAdapterProvider = Provider<XbConnectAdapter>(
  (ref) => const XbConnectAdapter(),
);
