/// 形态 A 速度卡（spec `xboard-form-a-ui-revamp` / W3.2 / R2.6·R2.7·R8.4）。
///
/// 三指标：下载 / 上传 / 延迟。**单行横排**（紧凑低高度）：每张卡一行 = 方向图标 + 数值（单位内联），
/// 靠图标区分（下载品牌色 / 上传绿色 / 延迟中性），去独立标签行降高度。
/// - 速率单位**动态**（R2.6 比特/秒口径，×8）：<1Mbps 显 **Kbps**，≥1Mbps 显 **Mbps**，
///   单位标签随数值切换（下载/上传各自判定）。
/// - 上传数字**不标绿**（R2.7）：数值与下载同色（onSurface），仅图标用绿区分方向。
/// - 等宽数字 `tabular-nums`（R8.4）：跳变不抖动。
///
/// **适配层铁律**：读 `XbTrafficAdapter`（W2.2），不直接碰 FlClash provider。
/// 延迟来自外部传入（当前线路延迟，HomeTab 接线；未连接 `--`）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fl_clash/xboard/widgets/xb_theme.dart' show XbTokens;
import '../../adapters/xb_traffic_adapter.dart';

/// 速度卡。
class XbSpeedCard extends ConsumerWidget {
  const XbSpeedCard({super.key, this.latencyMs});

  /// 当前线路延迟（ms）；null = 未连接 / 未知（显示 `--`）。
  final int? latencyMs;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final adapter = ref.watch(xbTrafficAdapterProvider);
    final traffic = adapter.currentTraffic(ref);

    final down = _fmtSpeed(traffic.down);
    final up = _fmtSpeed(traffic.up);
    final hasLatency = latencyMs != null;
    // 三张独立卡（各带圆角 + 细边 + 阴影），单行横排。
    return Row(
      children: [
        Expanded(
          child: _Metric(
            icon: Icons.south,
            iconColor: scheme.primary,
            value: down.value,
            unit: down.unit,
          ),
        ),
        const SizedBox(width: 9),
        Expanded(
          child: _Metric(
            icon: Icons.north,
            iconColor: XbTokens.ok,
            value: up.value,
            unit: up.unit,
          ),
        ),
        const SizedBox(width: 9),
        Expanded(
          child: _Metric(
            icon: Icons.network_ping,
            iconColor: scheme.onSurfaceVariant,
            value: hasLatency ? latencyMs.toString() : '--',
            unit: hasLatency ? 'ms' : '',
          ),
        ),
      ],
    );
  }

  /// 字节/秒 → 速率串 + 单位：<1Mbps 显 **Kbps**，≥1Mbps 显 **Mbps**（R2.6 仍是比特/秒口径，
  /// ×8）。低网速用 Kbps 更直观，达到 1Mbps 才切 Mbps。
  static ({String value, String unit}) _fmtSpeed(num bytesPerSec) {
    final kbps = bytesPerSec * 8 / 1000;
    if (kbps <= 0) return (value: '0', unit: 'Kbps');
    if (kbps < 1000) return (value: kbps.round().toString(), unit: 'Kbps');
    final mbps = kbps / 1000;
    return (
      value: mbps >= 100 ? mbps.round().toString() : mbps.toStringAsFixed(1),
      unit: 'Mbps',
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({
    required this.icon,
    required this.iconColor,
    required this.value,
    required this.unit,
  });

  final IconData icon;
  final Color iconColor;
  final String value;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 15, color: iconColor),
          const SizedBox(width: 6),
          // 数值（单位内联，小一号灰色）；等宽数字（R8.4）。
          RichText(
            text: TextSpan(
              text: value,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                // 上传不标绿（R2.7）：数值统一 onSurface。
                color: scheme.onSurface,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
              children: unit.isEmpty
                  ? null
                  : [
                      TextSpan(
                        text: ' $unit',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w500,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
            ),
          ),
        ],
      ),
    );
  }
}
