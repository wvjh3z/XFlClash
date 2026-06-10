/// 形态 A 当前线路卡（spec `xboard-form-a-ui-revamp` / W3.3 / R2.8）。
///
/// **显示口径（修正）**：只要用户在节点页选了节点（无论是否已连接），上行显示**生效节点名**、
/// 下行显示**「当前分组：X」**（原型 curnode）。仅当确实无任何选中（全空链）时显示占位。
/// 点击 → 切到节点 Tab（回调）。
///
/// **适配层铁律**：经 `XbConnectAdapter`（连接态，仅决定图标高亮）+ `XbNodesAdapter`
/// （当前选中节点 + 分组）读取，不直接碰 FlClash provider。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../adapters/xb_nodes_adapter.dart';

/// 当前线路卡。
class XbLineCard extends ConsumerWidget {
  const XbLineCard({super.key, this.onTapToNodes});

  /// 点击切到节点 Tab 的回调（shell 注入）。带上当前生效节点的所属分组名 +
  /// 节点名，供节点页打开时定位到该分组并把该节点滚动到尽量居中。无选中则传 (null, null)。
  final void Function(String? group, String? node)? onTapToNodes;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nodesAdapter = ref.watch(xbNodesAdapterProvider);
    final scheme = Theme.of(context).colorScheme;

    final selection = nodesAdapter.currentSelection(ref);
    // 只要有生效节点就显示它（不依赖连接态）：上行节点名，下行「当前分组：X」。
    // 无任何选中（全空链）→ 占位引导。
    final hasSelection = selection.node != null && selection.node!.isNotEmpty;
    final String title;
    final String subtitle;
    if (hasSelection) {
      title = selection.node!;
      subtitle =
          selection.group != null ? '当前分组：${selection.group}' : '当前线路';
    } else {
      title = '未选择线路';
      subtitle = '连接后自动优选';
    }

    return Card(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      child: InkWell(
        onTap: onTapToNodes == null
            ? null
            : () => onTapToNodes!(selection.group, selection.node),
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      // 长分组名单行省略，防折行撑高线路卡。
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
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
}
