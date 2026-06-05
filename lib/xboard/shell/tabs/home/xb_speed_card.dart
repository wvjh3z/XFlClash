/// 形态 A 速度卡（spec `xboard-form-a-ui-revamp` / W3.2 / R2.6·R2.7·R8.4）。
///
/// 三指标：下载 / 上传 / 延迟。
/// - 速率单位 **Mbps**（兆比特/秒，非 MB/s；R2.6）：字节/秒 × 8 / 1e6。
/// - 上传数字**不标绿**（R2.7）：与下载同色（onSurface），不用语义绿。
/// - 等宽数字 `tabular-nums`（R8.4）：跳变不抖动。
///
/// **适配层铁律**：读 `XbTrafficAdapter`（W2.2），不直接碰 FlClash provider。
/// 延迟来自外部传入（当前线路延迟，HomeTab 接线；未连接 `--`）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../adapters/xb_traffic_adapter.dart';

/// 速度卡。
class XbSpeedCard extends ConsumerWidget {
  const XbSpeedCard({super.key, this.latencyMs});

  /// 当前线路延迟（ms）；null = 未连接 / 未知（显示 `--`）。
  final int? latencyMs;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final adapter = ref.watch(xbTrafficAdapterProvider);
    final traffic = adapter.currentTraffic(ref);

    // 原型：三张独立卡（各带圆角 + 细边 + 阴影），而非单卡竖线分隔。
    return Row(
      children: [
        Expanded(child: _Metric(value: _toMbps(traffic.down), label: '下载 Mbps')),
        const SizedBox(width: 11),
        Expanded(child: _Metric(value: _toMbps(traffic.up), label: '上传 Mbps')),
        const SizedBox(width: 11),
        Expanded(
          child: _Metric(
            value: latencyMs?.toString() ?? '--',
            label: '延迟 ms',
          ),
        ),
      ],
    );
  }

  /// 字节/秒 → Mbps（× 8 bit / 1e6），保留 1 位小数。
  static String _toMbps(num bytesPerSec) {
    final mbps = bytesPerSec * 8 / 1000000;
    return mbps.toStringAsFixed(1);
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(17),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 21,
              fontWeight: FontWeight.w800,
              // 上传不标绿（R2.7）：统一 onSurface；等宽数字（R8.4）。
              color: scheme.onSurface,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 3),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
