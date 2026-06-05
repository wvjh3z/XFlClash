/// 形态 A 当前线路卡（spec `xboard-form-a-ui-revamp` / W3.3 / R2.8）。
///
/// 已连接显示当前线路名；未连接显示「连接后自动优选」。点击 → 切到节点 Tab（回调）。
///
/// **适配层铁律**：经 `XbConnectAdapter`（连接态）+ `XbNodesAdapter`（当前线路名）读取，
/// 不直接碰 FlClash provider。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../adapters/xb_connect_adapter.dart';
import '../../adapters/xb_nodes_adapter.dart';

/// 当前线路卡。
class XbLineCard extends ConsumerWidget {
  const XbLineCard({super.key, this.onTapToNodes});

  /// 点击切到节点 Tab 的回调（shell 注入）。
  final VoidCallback? onTapToNodes;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connectAdapter = ref.watch(xbConnectAdapterProvider);
    final nodesAdapter = ref.watch(xbNodesAdapterProvider);
    final scheme = Theme.of(context).colorScheme;

    final state = connectAdapter.connState(ref);
    final connectedOrConnecting =
        state == XbConnState.connected || state == XbConnState.connecting;

    final lineName = _currentLineName(nodesAdapter, ref);
    final title = connectedOrConnecting
        ? (lineName ?? '智能优选')
        : '未选择线路';
    final subtitle = connectedOrConnecting ? '当前线路' : '连接后自动优选';

    return Card(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      child: InkWell(
        onTap: onTapToNodes,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
          child: Row(
            children: [
              Icon(Icons.bolt, color: scheme.primary, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }

  /// 当前线路名：取第一个有选中节点的可见分组的 currentSelected。
  String? _currentLineName(XbNodesAdapter adapter, WidgetRef ref) {
    final view = adapter.nodesView(ref);
    for (final g in view.groups) {
      if (g.currentSelected.isNotEmpty) return g.currentSelected;
    }
    return null;
  }
}
