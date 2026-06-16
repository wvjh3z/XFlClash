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

import 'package:fl_clash/xboard/widgets/xb_theme.dart' show XbTokens;
import '../../adapters/xb_nodes_adapter.dart';

/// 当前线路卡。
class XbLineCard extends ConsumerWidget {
  const XbLineCard({super.key, this.onTapToNodes, this.embedded = false});

  /// 点击切到节点 Tab 的回调（shell 注入）。带上当前生效节点的所属分组名 +
  /// 节点名，供节点页打开时定位到该分组并把该节点滚动到尽量居中。无选中则传 (null, null)。
  final void Function(String? group, String? node)? onTapToNodes;

  /// 嵌入模式（桌面右栏「当前线路」标题卡内）：去掉自身 Card 外壳与内边距，
  /// 只渲染「节点名 + 分组 + chevron」行（外层标题卡已提供卡片样式）。
  final bool embedded;

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

    if (embedded) {
      return _embeddedRow(context, ref, title, subtitle, selection);
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
          child: _row(scheme, title, subtitle),
        ),
      ),
    );
  }

  /// 嵌入模式：无 Card 外壳，直接行（外层标题卡提供卡片样式）。
  /// 原型 `.lrow`：左国旗方块 + 节点名（去旗）+ 分组 + chevron，与出口信息卡同语言。
  Widget _embeddedRow(BuildContext context, WidgetRef ref, String title,
      String subtitle, dynamic selection) {
    final t = XbTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final (flag, name) = _splitFlag(title);
    return InkWell(
      onTap: onTapToNodes == null
          ? null
          : () => onTapToNodes!(selection.group, selection.node),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            // 国旗方块（原型 .lflag）；无可识别国旗时退回通用网络图标。
            Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: t.sfc,
                borderRadius: BorderRadius.circular(11),
              ),
              child: flag != null
                  ? Text(flag, style: const TextStyle(fontSize: 21))
                  : Icon(Icons.lan_outlined, size: 19, color: t.onv),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }

  /// 拆分名称前导国旗 emoji（两个区域指示符）：返回 (国旗?, 去旗名称)。
  static (String?, String) _splitFlag(String name) {
    final runes = name.runes.toList();
    bool isRI(int r) => r >= 0x1F1E6 && r <= 0x1F1FF;
    if (runes.length >= 2 && isRI(runes[0]) && isRI(runes[1])) {
      final flag = String.fromCharCodes(runes.take(2));
      final rest = String.fromCharCodes(runes.skip(2)).trim();
      return (flag, rest.isEmpty ? name : rest);
    }
    return (null, name);
  }

  Widget _row(ColorScheme scheme, String title, String subtitle) {
    return Row(
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
    );
  }
}
