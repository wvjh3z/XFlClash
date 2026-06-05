/// 形态 A 速度适配器（spec `xboard-form-a-ui-revamp` / W2.2 / R2.6·R2.7）。
///
/// **职责（风险②b 收口）**：把 FlClash `trafficsProvider`（最新一帧实时速率）收口成形态 A
/// 速度卡需要的 `({num up, num down})`。Tab 不直接 watch FlClash provider。
///
/// **类型注意（第一轮检查）**：`Traffic.up` / `Traffic.down` 是 `num`（不是 `int`）。
library;

import 'package:fl_clash/models/models.dart' show Traffic;
import 'package:fl_clash/providers/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 形态 A 实时速率视图（字节/秒；UI 层换算成 Mbps 显示）。
typedef XbTraffic = ({num up, num down});

/// 速度适配器。
class XbTrafficAdapter {
  const XbTrafficAdapter();

  /// 当前实时速率（取 `trafficsProvider` 列表最新一帧，空则 0/0）。
  XbTraffic currentTraffic(WidgetRef ref) {
    final traffic = ref.watch(
      trafficsProvider.select(
        (s) => s.list.isEmpty ? const Traffic() : s.list.last,
      ),
    );
    return (up: traffic.up, down: traffic.down);
  }
}

/// 速度适配器单例 provider（Tab 经此取，测试可 override）。
final xbTrafficAdapterProvider = Provider<XbTrafficAdapter>(
  (ref) => const XbTrafficAdapter(),
);
