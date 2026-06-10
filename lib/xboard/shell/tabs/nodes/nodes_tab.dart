/// 形态 A 节点 Tab（spec `xboard-form-a-ui-revamp` / W4.1·W4.2 / R4.1-R4.7）。
///
/// 组装：刷新按钮（R4.5，重拉订阅）+ 自绘分组/节点行（[XbNodeGroup]，原型 `.node` 列表行）+
/// 空态引导续费（R4.6）+ 游客引导（R4.7）。
///
/// **加而不改**：不再复用 FlClash `ProxyGroupView`/`ProxyCard`（网格卡），改自绘列表行；
/// 内核数据（延迟/选中/选择/测速）经 [XbNodesAdapter] 收口（适配层铁律），不直接碰 `lib/views/**`。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/services/xboard_subscription_service.dart';
import 'package:fl_clash/xboard/widgets/xb_components.dart';
import 'package:fl_clash/xboard/widgets/xb_feedback.dart' show xbToast;
import 'package:fl_clash/xboard/widgets/xb_theme.dart' show XbTokens;

import '../../adapters/xb_nodes_adapter.dart';
import 'xb_node_group.dart';

/// 节点 Tab。
class NodesTab extends ConsumerStatefulWidget {
  const NodesTab({
    super.key,
    this.onTapRenew,
    this.onTapLogin,
    this.targetGroup,
    this.targetNode,
    this.targetNonce = 0,
  });

  /// 空态点击续费（shell/我的 注入）。
  final VoidCallback? onTapRenew;

  /// 游客点击登录（shell 注入）。
  final VoidCallback? onTapLogin;

  /// 从首页「当前线路」进入时的目标分组名（打开即切到该分组）。null = 不定向。
  final String? targetGroup;

  /// 目标节点名（在分组内滚动到该节点并尽量上下居中）。
  final String? targetNode;

  /// 定向请求序号（shell 每次点线路卡自增）：用于即便目标相同也能再次触发定位。
  final int targetNonce;

  @override
  ConsumerState<NodesTab> createState() => _NodesTabState();
}

class _NodesTabState extends ConsumerState<NodesTab> {
  /// 正在刷新节点（重拉订阅 + 解密 + 写入新 profile）。期间刷新按钮禁用 + 顶部横幅；
  /// 旧节点保留显示（不清空），写入成功后 profile 重载自动覆盖。
  bool _refreshing = false;

  /// 当前选中的分组名（顶部 tab）。null = 用首个可见分组。
  String? _selectedGroup;

  /// 待定位到的节点名（传给 XbNodeGroup 滚动居中）；消费后清空（只定位一次）。
  String? _pendingScrollNode;

  /// 已处理的定向请求序号（避免重复定位）。
  int _handledNonce = 0;

  @override
  void initState() {
    super.initState();
    _applyTarget();
  }

  @override
  void didUpdateWidget(covariant NodesTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.targetNonce != _handledNonce) {
      setState(_applyTarget);
    }
  }

  /// 应用首页传入的定向：切到目标分组 + 记录待滚动节点。
  void _applyTarget() {
    _handledNonce = widget.targetNonce;
    if (widget.targetGroup != null) {
      _selectedGroup = widget.targetGroup;
      _pendingScrollNode = widget.targetNode;
    }
  }

  /// 刷新 = 重拉订阅并解密写入新节点（2-A）。await sync(force) 拿 `ok`（新 profile 写入成功）
  /// 才算完成；期间按钮禁用、显示横幅，完成后恢复。旧节点在写入成功前保持不变。
  Future<void> _refreshNodes() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    var outcome = XbSyncOutcome.failed;
    try {
      outcome = await ref
          .read(subscriptionServiceProvider)
          .sync(force: true);
    } catch (_) {
      // 永不抛（Property 1）；当作失败处理。
    }
    if (!mounted) return;
    setState(() => _refreshing = false);
    if (outcome != XbSyncOutcome.ok) {
      final msg = switch (outcome) {
        XbSyncOutcome.noSubscription => '当前套餐无可用线路，请购买套餐',
        XbSyncOutcome.authExpired => '登录已过期，请重新登录',
        _ => '刷新失败，请稍后重试',
      };
      xbToast(context, msg);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isGuest =
        ref.watch(authStateProvider) != AuthState.authenticated;
    if (isGuest) {
      return _GuestNodes(onTapLogin: widget.onTapLogin);
    }

    final adapter = ref.watch(xbNodesAdapterProvider);
    final view = adapter.nodesView(ref);

    // 空态：一个节点都没有。刷新中仍显示空态 + 横幅（旧节点本就为空，无可保留）。
    if (view.isEmpty) {
      return Column(
        children: [
          _NodesHeader(onRefresh: _refreshNodes, refreshing: _refreshing),
          if (_refreshing)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: XbSyncBanner(text: '正在刷新节点，请稍候…'),
            ),
          Expanded(
            child: _EmptyNodes(
              onTapRenew: widget.onTapRenew,
              // 空态「刷新重试」也走重拉订阅（与顶部刷新同链路）。
              onRefresh: _refreshNodes,
            ),
          ),
        ],
      );
    }

    // 选中分组：选中名不在当前可见分组里（刷新后分组变化）→ 回退首个。
    final groups = view.groups;
    final current = groups.firstWhere(
      (g) => g.name == _selectedGroup,
      orElse: () => groups.first,
    );

    // 顶部分组 tab（横向滚动）+ 只显示选中分组的节点（不再所有组堆叠）。
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _NodesHeader(onRefresh: _refreshNodes, refreshing: _refreshing),
        if (_refreshing)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: XbSyncBanner(text: '正在刷新节点，请稍候…'),
          ),
        _GroupTabBar(
          groups: groups,
          selected: current.name,
          onSelect: (name) => setState(() => _selectedGroup = name),
        ),
        Expanded(
          child: XbNodeGroup(
            // key 让切换分组时重建状态（测速态不串组）。
            key: ValueKey(current.name),
            group: current,
            // 仅当待定位节点确实属于当前分组时传入（滚动到它并尽量居中，只用一次）。
            scrollToNode: (_pendingScrollNode != null &&
                    current.nodes.any((n) => n.name == _pendingScrollNode))
                ? _pendingScrollNode
                : null,
            // 定位请求序号：同组重复点击线路卡也能再次触发居中（XbNodeGroup.didUpdateWidget）。
            scrollNonce: _handledNonce,
          ),
        ),
      ],
    );
  }
}

/// 顶部分组 tab（横向滚动 chips，原型 `.gtabs`）。选中高亮品牌色。
class _GroupTabBar extends StatelessWidget {
  const _GroupTabBar({
    required this.groups,
    required this.selected,
    required this.onSelect,
  });

  final List<XbGroupSummary> groups;
  final String selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 42,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
        itemCount: groups.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final g = groups[i];
          final on = g.name == selected;
          return GestureDetector(
            onTap: () => onSelect(g.name),
            child: Container(
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 15),
              decoration: BoxDecoration(
                gradient: on
                    ? LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          Color.alphaBlend(
                              Colors.white.withValues(alpha: 0.12),
                              scheme.primary),
                          scheme.primary,
                        ],
                      )
                    : null,
                // 未选：白卡底 + 细描边（清晰是可点 chip，深色下也跳出来）；选中：品牌渐变。
                color: on ? null : t.card,
                border: on
                    ? null
                    : Border.all(color: t.line, width: 1.4),
                borderRadius: BorderRadius.circular(30),
                boxShadow: on
                    ? [
                        BoxShadow(
                          color: scheme.primary.withValues(alpha: 0.45),
                          blurRadius: 16,
                          offset: const Offset(0, 6),
                          spreadRadius: -6,
                        ),
                      ]
                    : null,
              ),
              child: Text(
                g.name,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  color: on ? Colors.white : t.on,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 顶部刷新条（R4.5）—— 原型「选择线路」标题 + 「刷新节点」。刷新中按钮禁用 + 文案「刷新中…」。
class _NodesHeader extends StatelessWidget {
  const _NodesHeader({required this.onRefresh, this.refreshing = false});

  final VoidCallback onRefresh;
  final bool refreshing;

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    // 节点页专属紧凑标题行（不用共享 XbScreenTitle —— 它底部留白 12px 太大，与下方吸顶分组 tab
    // 间距过宽，和原型不符）。标题 + 右侧刷新，底部仅 2px 间距。
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 2),
      child: Row(
        children: [
          Text('选择线路',
              style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.4,
                  color: t.on)),
          const Spacer(),
          TextButton.icon(
            // 刷新中禁用（null onPressed → 自动变灰不可点）。
            onPressed: refreshing ? null : onRefresh,
            icon: refreshing
                ? const XbSpinner(color: XbTokens.warn, size: 16, stroke: 2)
                : const Icon(Icons.refresh, size: 16),
            label: Text(refreshing ? '刷新中…' : '刷新节点'),
            style: TextButton.styleFrom(foregroundColor: scheme.primary),
          ),
        ],
      ),
    );
  }
}

/// 空态：无可用分组 → 引导续费 + 刷新重试（R4.6，复用 XbEmptyState）。
class _EmptyNodes extends StatelessWidget {
  const _EmptyNodes({this.onTapRenew, this.onRefresh});

  final VoidCallback? onTapRenew;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    return XbEmptyState(
      icon: Icons.cloud_off,
      title: '当前套餐无可用线路',
      description: '套餐可能已到期或未生效，\n续费后线路将自动同步。',
      actionLabel: '前往续费',
      onAction: onTapRenew,
      secondaryLabel: '刷新重试',
      onSecondary: onRefresh,
    );
  }
}

/// 游客态：登录后查看专属线路（R4.7，复用 XbEmptyState）。
class _GuestNodes extends StatelessWidget {
  const _GuestNodes({this.onTapLogin});

  final VoidCallback? onTapLogin;

  @override
  Widget build(BuildContext context) {
    return XbEmptyState(
      icon: Icons.public,
      title: '登录后查看专属线路',
      description: '高速节点由服务端下发，\n登录账号即可同步全部线路。',
      actionLabel: '立即登录',
      actionIcon: Icons.login,
      onAction: onTapLogin,
    );
  }
}
