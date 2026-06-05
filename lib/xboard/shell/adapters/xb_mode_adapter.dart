/// 形态 A 代理模式适配器（spec `xboard-form-a-ui-revamp` / W2.3 / R3.1·R3.2）。
///
/// **职责（风险②b 收口 + direct 归一坑）**：形态 A 只暴露「智能 / 全局」二选一，但 FlClash
/// `Mode` 是三态 `{rule, global, direct}`。本适配器：
/// - 读：`rule→smart` / `global→global` / **`direct→smart`（归一）**（formA 二选一无法表达 direct）。
/// - 写：`smart→Mode.rule` / `global→Mode.global`，→ `setupActionProvider.changeMode`
///   （global→GLOBAL 组联动由 changeMode 内部处理，design 风险②）。
/// - 纠正：进 formA 首页时若检测到 `Mode.direct` → 主动 `setMode(smart)` 纠偏（design direct 坑）。
library;

import 'package:fl_clash/enum/enum.dart' show Mode;
import 'package:fl_clash/providers/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 形态 A 代理模式（外形层只认二态，不碰 FlClash 三态 Mode）。
enum XbMode {
  /// 智能：国内直连 + 海外走 VPN（= FlClash Mode.rule）。
  smart,

  /// 全局：全部流量走 VPN（= FlClash Mode.global）。
  global,
}

/// 代理模式适配器。
class XbModeAdapter {
  const XbModeAdapter();

  /// 当前模式（FlClash Mode 归一到 formA 二态；direct 归一为 smart）。
  XbMode currentMode(WidgetRef ref) {
    final mode = ref.watch(patchClashConfigProvider.select((s) => s.mode));
    return _toXbMode(mode);
  }

  /// FlClash Mode → formA XbMode（direct→smart 归一）。
  XbMode _toXbMode(Mode mode) => switch (mode) {
        Mode.rule => XbMode.smart,
        Mode.global => XbMode.global,
        Mode.direct => XbMode.smart, // 归一：formA 二选一无法表达 direct
      };

  /// formA XbMode → FlClash Mode。
  Mode _toFlClashMode(XbMode mode) => switch (mode) {
        XbMode.smart => Mode.rule,
        XbMode.global => Mode.global,
      };

  /// 设置模式 → `setupActionProvider.changeMode`（global→GLOBAL 联动内部处理）。
  void setMode(WidgetRef ref, XbMode mode) {
    ref.read(setupActionProvider.notifier).changeMode(_toFlClashMode(mode));
  }

  /// 进 formA 首页时纠偏：若内核当前是 `Mode.direct`（formA 无法表达）→ 主动改 smart。
  ///
  /// 幂等：非 direct 时 no-op。返回是否执行了纠正（便于测试 / 日志）。
  bool normalizeDirectIfNeeded(WidgetRef ref) {
    final mode = ref.read(patchClashConfigProvider.select((s) => s.mode));
    if (mode == Mode.direct) {
      ref.read(setupActionProvider.notifier).changeMode(Mode.rule);
      return true;
    }
    return false;
  }
}

/// 模式适配器单例 provider（Tab 经此取，测试可 override）。
final xbModeAdapterProvider = Provider<XbModeAdapter>(
  (ref) => const XbModeAdapter(),
);
