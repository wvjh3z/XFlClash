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
import 'package:flutter/rendering.dart' show RenderAbstractViewport;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fl_clash/xboard/widgets/xb_components.dart'
    show XbTag, XbInfoSheet, XbInfoItem, XbSpinner;
import 'package:fl_clash/xboard/widgets/xb_theme.dart' show XbTokens;

import '../../adapters/xb_nodes_adapter.dart';
import '../../sheets/sheet_scaffold.dart' show showXbBottomSheet;

/// 自绘分组区块：分组名 + 类型标签(含「?」说明) + 测延迟按钮 + 节点行列表。
class XbNodeGroup extends ConsumerStatefulWidget {
  const XbNodeGroup({
    super.key,
    required this.group,
    this.scrollToNode,
    this.scrollNonce = 0,
  });

  final XbGroupSummary group;

  /// 进入时滚动到该节点并尽量上下居中（不强制：靠顶/底则就近）。null = 不定位。
  final String? scrollToNode;

  /// 定位请求序号（首页每次点线路卡自增）：即便目标节点 / 分组都没变（同组重复点击），
  /// 序号变化也会经 [didUpdateWidget] 再次触发居中。避免「同组时 State 复用、initState
  /// 不重跑导致定位失效」（用户报告「修复没生效」的根因）。
  final int scrollNonce;

  @override
  ConsumerState<XbNodeGroup> createState() => _XbNodeGroupState();
}

class _XbNodeGroupState extends ConsumerState<XbNodeGroup> {
  /// 本组「测延迟」进行中（点测延迟 → true，本组全部节点拿到结果 → false）。
  bool _testing = false;

  /// 本轮测速已完成节点数（进度「测速中 N/M」用）。
  ///
  /// **为何用本地计数而非读延迟表**：重测时节点已有上次延迟值，core 把测速中节点逐个重置为 0
  /// 占位再回填真值，按「非0延迟节点数」估算会在 M↔M-1 间反复横跳（用户反馈「进度横跳」）。
  /// 改为 adapter 每个节点测速 future 完成时回调累加，done 单调递增，进度准确不回退。
  int _testedCount = 0;

  /// 列表滚动控制器（用于进入时定位到选中节点）。
  final ScrollController _scrollCtrl = ScrollController();

  /// 目标节点行的 key（用于精确计算居中偏移）。
  final GlobalKey _targetKey = GlobalKey();

  XbGroupSummary get group => widget.group;

  @override
  void initState() {
    super.initState();
    if (widget.scrollToNode != null) {
      // 首帧布局完成后把目标行滚动到视口中央（不强制：clamp 到可滚范围 → 靠边就近）。
      WidgetsBinding.instance.addPostFrameCallback((_) => _centerTarget());
    }
  }

  @override
  void didUpdateWidget(covariant XbNodeGroup oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 同组重复定位（State 复用、不重跑 initState）：scrollToNode 变化或 scrollNonce 自增
    // 都重新居中。首页点线路卡时即便目标节点/分组都没变也能再次触发（修「定位失效」）。
    if (widget.scrollToNode != null &&
        (widget.scrollToNode != oldWidget.scrollToNode ||
            widget.scrollNonce != oldWidget.scrollNonce)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _centerTarget());
    }
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  /// 把目标行滚到视口尽量居中（alignment=0.5）；clamp 到 [0,max] → 靠顶/底则就近。
  void _centerTarget() {
    if (!mounted || !_scrollCtrl.hasClients) return;
    final ctx = _targetKey.currentContext;
    if (ctx == null) return;
    final box = ctx.findRenderObject();
    if (box is! RenderBox) return;
    final viewport = RenderAbstractViewport.of(box);
    // alignment 0.5 = 目标行在视口垂直居中。
    final target = viewport.getOffsetToReveal(box, 0.5).offset;
    final max = _scrollCtrl.position.maxScrollExtent;
    final clamped = target.clamp(0.0, max);
    _scrollCtrl.animateTo(
      clamped,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  /// 测延迟：只测本组节点（不波及其它组）。await 完成后清测速态。
  Future<void> _testGroup() async {
    if (_testing) return;
    setState(() {
      _testing = true;
      _testedCount = 0;
    });
    try {
      await ref.read(xbNodesAdapterProvider).testGroupDelay(
        ref,
        group.name,
        onProgress: (done, total) {
          // 完成计数单调递增 → 进度不横跳。仅在 mounted 且仍在测速时更新。
          if (mounted && _testing) setState(() => _testedCount = done);
        },
      );
    } catch (_) {
      // 永不抛。
    }
    if (mounted) setState(() => _testing = false);
  }

  @override
  Widget build(BuildContext context) {
    final adapter = ref.watch(xbNodesAdapterProvider);
    final selected = adapter.selectedName(ref, group.name);
    // computed 组（url-test/fallback）是否自动模式（未手动锁定）：决定「自动」标签标在哪个节点。
    final autoMode = group.isComputed && adapter.isAutoMode(ref, group.name);

    // 测速进度（N/M）：用本地完成计数器（adapter 回调累加，单调递增不横跳），
    // 不再读延迟表统计「非0节点数」（重测时会 M↔M-1 横跳，见 _testedCount 注释）。
    final tested = _testedCount;

    // 选中分组的节点列表（可滚动）；头部为「类型标签 + 测延迟」行（分组名已由顶部 tab 显示）。
    return ListView(
      controller: _scrollCtrl,
      // 定位场景：放大缓存范围，确保目标行（可能在视口外）已 build → GlobalKey 可解析居中。
      // ignore: deprecated_member_use
      cacheExtent: widget.scrollToNode != null ? 5000.0 : null,
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 24),
      children: [
        // 分组头：类型标签（带 ? 说明）左、测延迟右（所有分组都可测）。
        Padding(
          padding: const EdgeInsets.fromLTRB(0, 0, 0, 8),
          child: Row(
            children: [
              Expanded(child: Align(
                alignment: Alignment.centerLeft,
                child: _TypeChip(kind: group.kind),
              )),
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
            key: widget.scrollToNode == n.name ? _targetKey : null,
            group: group,
            node: n,
            // 计算选择组：选中=当前生效节点；selector：选中=手选名。
            isSelected: group.isSelectable && selected == n.name,
            // 「自动」标签：computed 组自动模式下，标在 core 当前命中的那个节点（=selected），
            // 而非固定第一项（修「自动恒在第一个、不随延迟变」）。
            isAutoHit: autoMode && selected == n.name,
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
      builder: (_) => XbGroupTypeInfoSheet(kind: kind),
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
        icon: const XbSpinner(color: XbTokens.warn, size: 13, stroke: 2),
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
    super.key,
    required this.group,
    required this.node,
    required this.isSelected,
    this.isAutoHit = false,
    this.onTap,
  });

  final XbGroupSummary group;
  final XbNodeItem node;
  final bool isSelected;

  /// computed 组自动模式下，本节点是否 core 当前命中节点（标「自动」标签）。
  final bool isAutoHit;

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = XbTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final adapter = ref.watch(xbNodesAdapterProvider);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
          color: isSelected
              ? Color.alphaBlend(scheme.primary.withValues(alpha: 0.07), t.card)
              : t.card,
          borderRadius: BorderRadius.circular(XbTokens.rMd),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(XbTokens.rMd),
            child: Ink(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(XbTokens.rMd),
                border: Border.all(
                  color: isSelected ? scheme.primary : t.line,
                  width: isSelected ? 1.4 : 1,
                ),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              child: Row(
                children: [
                  // 节点名占据剩余空间（Expanded，单独 ellipsis），右侧依次「自动」/延迟/勾。
                  Expanded(
                    child: Text(
                      node.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: isSelected
                            ? FontWeight.w600
                            : FontWeight.w500,
                        color: t.on,
                      ),
                    ),
                  ),
                  if (isAutoHit) ...[
                    const SizedBox(width: 8),
                    const XbTag('自动'),
                  ],
                  const SizedBox(width: 10),
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
    // 首页「3 次取最低」测速中：屏蔽中间跳变，统一显示转圈（测完写入最低值后解除）。
    final measuring = ref.watch(xbMeasuringNodesProvider).contains(proxyName);

    void test() {
      // ignore: discarded_futures
      adapter.testNode(ref, proxyName: proxyName, type: type, testUrl: testUrl);
    }

    if (measuring || delay == 0) {
      // 测速中（首页 3 次取最低 / 单次 core 测速占位 0）：琥珀黄转圈（原型 .spin = warn，
      // 非品牌红 CircularProgressIndicator）。
      return const XbSpinner(color: XbTokens.warn, size: 16, stroke: 2);
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
          fontWeight: FontWeight.w500,
          color: adapter.delayColor(delay) ?? scheme.onSurfaceVariant,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

/// 线路分组类型说明 sheet（节点页类型标签 ? 触发；复用代理模式说明 modeexp 风格）。
/// 点哪个分组的 ? 就只显示该类型的说明（不一次列全 5 种）。
class XbGroupTypeInfoSheet extends StatelessWidget {
  const XbGroupTypeInfoSheet({super.key, required this.kind});

  final XbGroupKind kind;

  static (IconData, String, String) _entry(XbGroupKind k) => switch (k) {
        XbGroupKind.urlTest => (
            Icons.bolt,
            'url-test',
            '自动测速，始终用延迟最低的节点；也可手动点定某个节点锁定（再点一次该节点恢复自动）。日常推荐。',
          ),
        XbGroupKind.selector => (
            Icons.touch_app,
            'selector',
            '手动选择，点哪个用哪个，不会自动切换。',
          ),
        XbGroupKind.fallback => (
            Icons.swap_horiz,
            'fallback',
            '故障转移：按顺序优先用靠前的节点，当前不可用时自动跳到下一个；也可手动锁定。',
          ),
        XbGroupKind.loadBalance => (
            Icons.hub,
            'load-balance',
            '负载均衡：流量由系统在组内多个节点间自动分摊，无需也无法手动指定单个节点。',
          ),
        XbGroupKind.relay => (
            Icons.link,
            'relay',
            '链式中转：多个节点串成固定链路（入口→中转→出口），链路固定，不能单独选某个节点。',
          ),
      };

  @override
  Widget build(BuildContext context) {
    final (icon, title, desc) = _entry(kind);
    // 共用说明弹窗：顶部该类型图标圆徽 + 标题居中 + 纯文字说明卡（不重复图标）+ 品牌「知道了」。
    return XbInfoSheet(
      title: '线路分组类型说明',
      subtitle: title, // 副标题 = 该类型名（如 url-test）
      headerIcon: icon,
      items: [XbInfoItem(title: title, desc: desc)],
    );
  }
}
