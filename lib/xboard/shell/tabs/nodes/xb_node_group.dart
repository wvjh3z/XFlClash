/// 形态 A 自绘节点分组 + 节点行（spec `xboard-form-a-ui-revamp` / R4.1-R4.4 原型 `.node`）。
///
/// **「加而不改」**：不再复用 FlClash `ProxyGroupView`/`ProxyCard`（网格卡，与原型列表行不符），
/// 改为自绘列表行（国旗+名 · 延迟着色 · 选中勾）。一切内核数据（延迟/选中/选择/测速）经
/// [XbNodesAdapter] 收口读写——本文件**不直接 import** `lib/views/**` 或 FlClash provider，
/// 守适配层铁律。
///
/// 分组类型（[XbGroupKind]）决定交互：
/// - url-test / fallback（计算选择）：首项标「自动」，点节点锁定 / 再点解锁跟自动；
/// - selector：手选；
/// - load-balance / relay：只读（不可手选单节点），节点行 dim 不可点。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fl_clash/xboard/widgets/xb_components.dart' show XbTag;
import 'package:fl_clash/xboard/widgets/xb_theme.dart' show XbTokens;

import '../../adapters/xb_nodes_adapter.dart';
import '../../sheets/sheet_scaffold.dart' show showXbBottomSheet;

/// 自绘分组区块：分组名 + 类型标签(含「?」说明) + 测延迟按钮 + 节点行列表。
class XbNodeGroup extends ConsumerStatefulWidget {
  const XbNodeGroup({super.key, required this.group});

  final XbGroupSummary group;

  @override
  ConsumerState<XbNodeGroup> createState() => _XbNodeGroupState();
}

class _XbNodeGroupState extends ConsumerState<XbNodeGroup> {
  /// 本组「测延迟」进行中（点测延迟 → true，本组全部节点拿到结果 → false）。
  bool _testing = false;

  XbGroupSummary get group => widget.group;

  /// 测延迟：只测本组节点（不波及其它组）。await 完成后清测速态。
  Future<void> _testGroup() async {
    if (_testing) return;
    setState(() => _testing = true);
    try {
      await ref.read(xbNodesAdapterProvider).testGroupDelay(ref, group.name);
    } catch (_) {
      // 永不抛。
    }
    if (mounted) setState(() => _testing = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    final adapter = ref.watch(xbNodesAdapterProvider);
    final selected = adapter.selectedName(ref, group.name);

    // 测速进度（N/M）：测速中时统计本组已拿到结果（delay 非 null 非 0）的节点数。
    int tested = 0;
    if (_testing) {
      for (final n in group.nodes) {
        final d = adapter.nodeDelay(ref, proxyName: n.name, testUrl: n.testUrl);
        if (d != null && d != 0) tested++;
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 分组头：名 + 类型标签（带 ? 说明）+ 测延迟（所有分组都可测）。
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 14, 4, 9),
          child: Row(
            children: [
              Flexible(
                child: Text(
                  group.name,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w800,
                    color: t.onv,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _TypeChip(kind: group.kind),
              const Spacer(),
              _DelayTestButton(
                testing: _testing,
                tested: tested,
                total: group.nodes.length,
                onTap: _testGroup,
              ),
            ],
          ),
        ),
        // 节点行。
        ...group.nodes.map(
          (n) => _NodeRow(
            group: group,
            node: n,
            // 计算选择组：选中=当前生效节点；selector：选中=手选名。
            isSelected: group.isSelectable && selected == n.name,
            onTap: group.isSelectable
                ? () => adapter.selectNode(
                      ref,
                      group.name,
                      n.name,
                      computed: group.isComputed,
                    )
                : null,
          ),
        ),
      ],
    );
  }
}

/// 类型标签胶囊：`url-test(自动选择低延迟节点) ?`，点 ? 弹完整说明 sheet。
class _TypeChip extends StatelessWidget {
  const _TypeChip({required this.kind});

  final XbGroupKind kind;

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    return GestureDetector(
      onTap: () => _showInfo(context),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
        decoration: BoxDecoration(
          color: t.sfc,
          borderRadius: BorderRadius.circular(7),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${_kindLabel(kind)}(${_kindShort(kind)})',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: t.onv,
              ),
            ),
            const SizedBox(width: 3),
            Icon(Icons.help_outline, size: 15, color: t.onv),
          ],
        ),
      ),
    );
  }

  void _showInfo(BuildContext context) {
    showXbBottomSheet<void>(
      context: context,
      builder: (_) => const XbGroupTypeInfoSheet(),
    );
  }

  static String _kindLabel(XbGroupKind k) => switch (k) {
        XbGroupKind.urlTest => 'url-test',
        XbGroupKind.selector => 'selector',
        XbGroupKind.fallback => 'fallback',
        XbGroupKind.loadBalance => 'load-balance',
        XbGroupKind.relay => 'relay',
      };

  static String _kindShort(XbGroupKind k) => switch (k) {
        XbGroupKind.urlTest => '自动选择低延迟节点',
        XbGroupKind.selector => '手动选择节点',
        XbGroupKind.fallback => '故障转移',
        XbGroupKind.loadBalance => '负载均衡',
        XbGroupKind.relay => '链式中转',
      };
}

/// 测延迟按钮（分组头右侧）。测速中显示「测速中 N/M」+ 转圈。
class _DelayTestButton extends StatelessWidget {
  const _DelayTestButton({
    required this.onTap,
    this.testing = false,
    this.tested = 0,
    this.total = 0,
  });

  final VoidCallback onTap;
  final bool testing;
  final int tested;
  final int total;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (testing) {
      return TextButton.icon(
        onPressed: null, // 测速中禁用。
        icon: const SizedBox(
          width: 13,
          height: 13,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        label: Text('测速中 $tested/$total'),
        style: TextButton.styleFrom(
          foregroundColor: scheme.primary,
          disabledForegroundColor: scheme.primary.withValues(alpha: 0.7),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      );
    }
    return TextButton.icon(
      onPressed: onTap,
      icon: const Icon(Icons.bolt, size: 16),
      label: const Text('测延迟'),
      style: TextButton.styleFrom(
        foregroundColor: scheme.primary,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}

/// 自绘节点行（原型 `.node`）：国旗+名 · 延迟ms(着色) · 选中勾。
class _NodeRow extends ConsumerWidget {
  const _NodeRow({
    required this.group,
    required this.node,
    required this.isSelected,
    this.onTap,
  });

  final XbGroupSummary group;
  final XbNodeItem node;
  final bool isSelected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = XbTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final adapter = ref.watch(xbNodesAdapterProvider);
    final readOnly = !group.isSelectable;
    // 首项「自动」标记：计算选择组（url-test/fallback）第一项。
    final isAutoFirst = group.isComputed && group.nodes.isNotEmpty &&
        group.nodes.first.name == node.name;

    return Padding(
      padding: const EdgeInsets.only(bottom: 11),
      child: Opacity(
        opacity: readOnly ? 0.78 : 1,
        child: Material(
          color: isSelected
              ? Color.alphaBlend(scheme.primary.withValues(alpha: 0.07), t.card)
              : t.card,
          borderRadius: BorderRadius.circular(18),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(18),
            child: Ink(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: isSelected ? scheme.primary : t.line,
                  width: isSelected ? 1.4 : 1,
                ),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 15),
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      node.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: isSelected
                            ? FontWeight.w800
                            : FontWeight.w700,
                        color: t.on,
                      ),
                    ),
                  ),
                  if (isAutoFirst) ...[
                    const SizedBox(width: 8),
                    const XbTag('自动'),
                  ],
                  const Spacer(),
                  _DelayText(
                    proxyName: node.name,
                    type: node.type,
                    testUrl: node.testUrl,
                    adapter: adapter,
                  ),
                  if (isSelected) ...[
                    const SizedBox(width: 7),
                    Icon(Icons.check, size: 20, color: scheme.primary),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 延迟数字（着色 + 等宽）；未测显示「测速」闪电按钮，测速中转圈，有值显示「N ms」/「超时」。
class _DelayText extends ConsumerWidget {
  const _DelayText({
    required this.proxyName,
    required this.type,
    required this.testUrl,
    required this.adapter,
  });

  final String proxyName;
  final String type;
  final String? testUrl;
  final XbNodesAdapter adapter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final delay = adapter.nodeDelay(ref, proxyName: proxyName, testUrl: testUrl);

    void test() {
      // ignore: discarded_futures
      adapter.testNode(ref, proxyName: proxyName, type: type, testUrl: testUrl);
    }

    if (delay == 0) {
      // 测速中。
      return const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    if (delay == null) {
      // 未测 → 闪电按钮触发单节点测速。
      return InkWell(
        onTap: test,
        borderRadius: BorderRadius.circular(8),
        child: Icon(Icons.bolt, size: 18, color: scheme.onSurfaceVariant),
      );
    }
    return GestureDetector(
      onTap: test,
      child: Text(
        delay > 0 ? '$delay ms' : '超时',
        style: TextStyle(
          fontSize: 13.5,
          fontWeight: FontWeight.w800,
          color: adapter.delayColor(delay) ?? scheme.onSurfaceVariant,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

/// 线路分组类型说明 sheet（节点页类型标签 ? 触发；复用代理模式说明 modeexp 风格）。
class XbGroupTypeInfoSheet extends StatelessWidget {
  const XbGroupTypeInfoSheet({super.key});

  static const _items = <(IconData, String, String)>[
    (
      Icons.bolt,
      'url-test',
      '自动测速选择延迟最低的节点；也可手动锁定某个节点（锁定后不再自动切换，再次点击该节点可恢复自动）。日常推荐。',
    ),
    (Icons.touch_app, 'selector', '完全手动选择，点哪个用哪个，不会自动切换。'),
    (
      Icons.swap_horiz,
      'fallback',
      '故障转移：按顺序使用，当前节点不可用时自动切换到下一个可用节点；也可手动锁定。',
    ),
    (
      Icons.hub,
      'load-balance',
      '负载均衡：组内多个节点由系统自动分流承载流量，无需也无法手动选择单个节点。',
    ),
    (
      Icons.link,
      'relay',
      '链式中转：多个节点串联成固定链路（入口→中转→出口），链路固定，无法手动选择单个节点。',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('线路分组类型说明',
                  style: TextStyle(
                      fontSize: 20, fontWeight: FontWeight.w800, color: t.on)),
              const SizedBox(height: 4),
              Text('不同分组类型的选择方式不同',
                  style: TextStyle(fontSize: 13.5, color: t.onv)),
              const SizedBox(height: 16),
              for (final (icon, title, desc) in _items)
                Padding(
                  padding: const EdgeInsets.only(bottom: 11),
                  child: Container(
                    padding: const EdgeInsets.all(15),
                    decoration: BoxDecoration(
                      color: t.sfc,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 42,
                          height: 42,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: scheme.primary.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(13),
                          ),
                          child: Icon(icon, size: 22, color: scheme.primary),
                        ),
                        const SizedBox(width: 13),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(title,
                                  style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w800,
                                      color: t.on)),
                              const SizedBox(height: 4),
                              Text(desc,
                                  style: TextStyle(
                                      fontSize: 12.5,
                                      height: 1.6,
                                      color: t.onv)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 6),
              SizedBox(
                width: double.infinity,
                child: FilledButton.tonal(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('知道了'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
