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

import 'package:fl_clash/xboard/models/xb_domain_subscription.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/providers/user_profile_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/pages/plan_list_page.dart';
import 'package:fl_clash/xboard/pages/reset_traffic_page.dart';
import 'package:fl_clash/xboard/services/xboard_subscription_service.dart';
import 'package:fl_clash/xboard/widgets/xb_components.dart';
import 'package:fl_clash/xboard/widgets/xb_feedback.dart' show xbToast, xbBrandColor;
import 'package:fl_clash/xboard/widgets/xb_refresh_throttle_guard.dart';
import 'package:fl_clash/xboard/widgets/xb_theme.dart' show XbTokens, xbPush;

import '../../adapters/xb_nodes_adapter.dart';
import '../../widgets/xb_content_header.dart';
import '../../widgets/xb_responsive.dart';
import 'xb_node_group.dart';

/// 节点页 master-detail：可用宽 ≥ [XbBreakpoints.desktop] 才双栏（策略见 xb_responsive）。

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

class _NodesTabState extends ConsumerState<NodesTab>
    with XbRefreshThrottleGuard {
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
  /// 才算完成；期间按钮禁用、显示横幅，完成后恢复并开始 60s 冷却。旧节点在写入成功前保持不变。
  Future<void> _refreshNodes() async {
    if (_refreshing) return;
    // 套餐已过期 → 刷新无意义（不会有可用节点）。直接提示前往续费，不发刷新请求
    // （修「过期时刷新误报『登录已过期，请重新登录』」）。
    final sub = ref.read(userProfileProvider).asData?.value;
    if (sub != null && !sub.hasNoPlan && _isExpired(sub)) {
      xbToast(context, '套餐已过期，无法刷新节点，请前往续费');
      return;
    }
    if (throttled) {
      xbToast(context, '节点刚刷新过，请稍后再试');
      return;
    }
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
    startThrottle();
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

  /// 套餐是否已过期（expiredAt 非空且不在未来）。expiredAt==null = 长期有效（不算过期）。
  bool _isExpired(XbDomainSubscription sub) =>
      sub.expiredAt != null && !sub.expiredAt!.isAfter(DateTime.now());

  /// 空态外壳：顶部标题栏（含刷新节点）+ 刷新中横幅 + 居中空态体。
  /// 无可用线路 / 套餐过期 / 流量用尽三种空态共用（结构一致，仅 body 不同）。
  Widget _emptyShell(Widget body) {
    return Column(
      children: [
        _NodesHeader(
            onRefresh: _refreshNodes,
            refreshing: _refreshing,
            cooldownSec: cooldownSeconds),
        if (_refreshing)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: XbSyncBanner(text: '正在刷新节点，请稍候…'),
          ),
        Expanded(child: body),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final isGuest =
        ref.watch(authStateProvider) != AuthState.authenticated;
    if (isGuest) {
      return _GuestNodes(onTapLogin: widget.onTapLogin);
    }

    // 账号到期 / 流量用尽 → 清空节点显示（即便有缓存节点也不再展示，避免误连失效线路）。
    // 优先级：套餐过期 > 流量用尽（过期时买流量包无意义，应引导续费/购买）。loading/无套餐不 gate。
    final sub = ref.watch(userProfileProvider).asData?.value;
    if (sub != null && !sub.hasNoPlan) {
      if (_isExpired(sub)) {
        return _emptyShell(_EmptyNodes(onTapRenew: widget.onTapRenew));
      }
      final exhausted = sub.totalBytes > 0 && sub.usedBytes >= sub.totalBytes;
      if (exhausted) {
        return _emptyShell(_ExhaustedNodes(
          onBuyResetPack: () {
            final id = sub.planId;
            if (id != null) {
              xbPush(context,
                  ResetTrafficPage(planId: id, planName: sub.planName),
                  brandColor: xbBrandColor());
            } else {
              xbPush(context, const PlanListPage(), brandColor: xbBrandColor());
            }
          },
          onBuyPlan: () =>
              xbPush(context, const PlanListPage(), brandColor: xbBrandColor()),
        ));
      }
    }

    final adapter = ref.watch(xbNodesAdapterProvider);
    final view = adapter.nodesView(ref);

    // 空态：一个节点都没有。刷新中仍显示空态 + 横幅（旧节点本就为空，无可保留）。
    if (view.isEmpty) {
      return _emptyShell(_EmptyNodes(onTapRenew: widget.onTapRenew));
    }

    // 选中分组：选中名不在当前可见分组里（刷新后分组变化）→ 回退首个。
    final groups = view.groups;
    final current = groups.firstWhere(
      (g) => g.name == _selectedGroup,
      orElse: () => groups.first,
    );

    // 顶部分组 tab：窄窗口横向；宽窗口 master-detail（左竖排分组栏 + 右双列节点网格，C-分支）。
    final scrollNode = (_pendingScrollNode != null &&
            current.nodes.any((n) => n.name == _pendingScrollNode))
        ? _pendingScrollNode
        : null;
    final header = _NodesHeader(
        onRefresh: _refreshNodes,
        refreshing: _refreshing,
        cooldownSec: cooldownSeconds);
    final banner = _refreshing
        ? const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: XbSyncBanner(text: '正在刷新节点，请稍候…'),
          )
        : null;

    return LayoutBuilder(
      builder: (context, constraints) {
        final masterDetail =
            xbIsDesktopWidth(constraints.maxWidth);
        if (masterDetail) {
          // 标题栏与下方内容区用同一 maxW（同居中限宽）→ 顶部「刷新节点」与分组头「测延迟」
          // 右缘严格对齐（修宽窗口下 md 限 1000 居中、而标题栏全宽导致的错位）。
          final maxW = xbContentMaxWidth(constraints.maxWidth);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 桌面固定标题栏（原型 .chd）：标题「选择线路」+ 右侧刷新，带底部分隔线。
              XbContentHeader(
                title: '选择线路',
                maxContentWidth: maxW,
                trailing: _NodesRefreshAction(
                  onRefresh: _refreshNodes,
                  refreshing: _refreshing,
                  cooldownSec: cooldownSeconds,
                ),
              ),
              ?banner,
              Expanded(
                // 原型 .md：max-width 1000 居中，rail 与节点网格之间 20px 留白（无分隔线）。
                child: Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: maxW),
                    child: Padding(
                      // 横向 28 与固定标题栏 XbContentHeader（padding 28）对齐 → 顶部「刷新节点」
                      // 与分组头「测延迟」右缘对齐、rail 左缘与标题对齐（原型屏2）。
                      padding: const EdgeInsets.symmetric(horizontal: 28),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _GroupRail(
                            groups: groups,
                            selected: current.name,
                            onSelect: (name) =>
                                setState(() => _selectedGroup = name),
                          ),
                          const SizedBox(width: 20),
                          Expanded(
                            child: XbNodeGroup(
                              key: ValueKey(current.name),
                              group: current,
                              columns: 2,
                              scrollToNode: scrollNode,
                              scrollNonce: _handledNonce,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        }
        // 移动端：顶部横向分组 tab + 单列节点列表。
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            header,
            ?banner,
            _GroupTabBar(
              groups: groups,
              selected: current.name,
              onSelect: (name) => setState(() => _selectedGroup = name),
            ),
            Expanded(
              child: XbNodeGroup(
                key: ValueKey(current.name),
                group: current,
                scrollToNode: scrollNode,
                scrollNonce: _handledNonce,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 桌面 master-detail 左侧分组栏（原型屏2 `.md-rail`）：「线路分组」小标题 + 竖排分组 pill。
class _GroupRail extends StatelessWidget {
  const _GroupRail({
    required this.groups,
    required this.selected,
    required this.onSelect,
  });

  final List<XbGroupSummary> groups;
  final String selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 200,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(0, 2, 0, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
              child: Text(
                '线路分组',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            _GroupTabBar(
              groups: groups,
              selected: selected,
              onSelect: onSelect,
              axis: Axis.vertical,
            ),
          ],
        ),
      ),
    );
  }
}

/// 顶部分组 tab（横向滚动 chips，原型 `.gtabs`）。选中高亮品牌色。
class _GroupTabBar extends StatelessWidget {
  const _GroupTabBar({
    required this.groups,
    required this.selected,
    required this.onSelect,
    this.axis = Axis.horizontal,
  });

  final List<XbGroupSummary> groups;
  final String selected;
  final ValueChanged<String> onSelect;

  /// 排布方向：移动端顶部横向 chips（默认）；桌面 master-detail 左栏竖向列表。
  /// 竖版由后续桌面节点布局接入（C-分支）使用。
  final Axis axis;

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (axis == Axis.vertical) {
      // 桌面左栏：竖向全宽 pill 列表。
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final g in groups) ...[
            _chip(context, t, scheme, g, g.name == selected),
            const SizedBox(height: 6),
          ],
        ],
      );
    }
    // 移动端：顶部横向滚动 chips。
    return SizedBox(
      height: 42,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
        itemCount: groups.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final g = groups[i];
          return _chip(context, t, scheme, g, g.name == selected);
        },
      ),
    );
  }

  /// 单个分组 chip（横/竖通用；竖向左对齐全宽，横向居中自适应）。
  Widget _chip(
    BuildContext context,
    XbTokens t,
    ColorScheme scheme,
    XbGroupSummary g,
    bool on,
  ) {
    final vertical = axis == Axis.vertical;
    return GestureDetector(
      onTap: () => onSelect(g.name),
      child: Container(
        alignment: vertical ? Alignment.centerLeft : Alignment.center,
        padding: vertical
            ? const EdgeInsets.symmetric(horizontal: 14, vertical: 12)
            : const EdgeInsets.symmetric(horizontal: 15),
        decoration: BoxDecoration(
          gradient: on
              ? LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Color.alphaBlend(
                        Colors.white.withValues(alpha: 0.12), scheme.primary),
                    scheme.primary,
                  ],
                )
              : null,
          // 未选：白卡底 + 细描边（清晰是可点 chip，深色下也跳出来）；选中：品牌渐变。
          color: on ? null : t.card,
          border: on ? null : Border.all(color: t.line, width: 1.4),
          borderRadius: BorderRadius.circular(vertical ? 16 : 30),
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
        // 竖排（桌面分组栏）：名左 + 节点数徽标右（原型 .vtab .cnt）。横排只显示名。
        child: vertical
            ? Row(
                children: [
                  Expanded(
                    child: Text(
                      g.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: on ? Colors.white : t.on,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _CountBadge(count: g.nodes.length, selected: on),
                ],
              )
            : Text(
                g.name,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  color: on ? Colors.white : t.on,
                ),
              ),
      ),
    );
  }
}

/// 分组栏节点数徽标（原型 `.vtab .cnt`）：选中态白色半透明底，未选 sfc 底。
class _CountBadge extends StatelessWidget {
  const _CountBadge({required this.count, required this.selected});

  final int count;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      decoration: BoxDecoration(
        color: selected ? Colors.white.withValues(alpha: 0.22) : t.sfc,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        '$count',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: selected ? Colors.white : t.onv,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

/// 顶部刷新条（R4.5）—— 原型「选择线路」标题 + 「刷新节点」。刷新中按钮禁用 + 文案「刷新中…」。
class _NodesHeader extends StatelessWidget {
  const _NodesHeader({
    required this.onRefresh,
    this.refreshing = false,
    this.cooldownSec = 0,
  });

  final VoidCallback onRefresh;
  final bool refreshing;
  final int cooldownSec;

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
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
          _NodesRefreshAction(
            onRefresh: onRefresh,
            refreshing: refreshing,
            cooldownSec: cooldownSec,
          ),
        ],
      ),
    );
  }
}

/// 「刷新节点」操作按钮（移动端标题行 / 桌面 .chd 标题栏共用）。
/// 刷新中→「刷新中…」转圈禁用；冷却中→「刷新节点 Ns」灰色（仍可点弹冷却提示）。
class _NodesRefreshAction extends StatelessWidget {
  const _NodesRefreshAction({
    required this.onRefresh,
    this.refreshing = false,
    this.cooldownSec = 0,
  });

  final VoidCallback onRefresh;
  final bool refreshing;
  final int cooldownSec;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final coolingDown = cooldownSec > 0;
    final String label;
    if (refreshing) {
      label = '刷新中…';
    } else if (coolingDown) {
      label = '刷新节点 ${cooldownSec}s';
    } else {
      label = '刷新节点';
    }
    return TextButton.icon(
      // 真正刷新中才禁用（null）；冷却中保持可点 → 触发 _refreshNodes 内的冷却 toast。
      onPressed: refreshing ? null : onRefresh,
      icon: refreshing
          ? const XbSpinner(color: XbTokens.warn, size: 16, stroke: 2)
          : Icon(Icons.refresh,
              size: 16,
              color: coolingDown
                  ? scheme.onSurfaceVariant.withValues(alpha: 0.5)
                  : scheme.primary),
      label: Text(label),
      style: TextButton.styleFrom(
        foregroundColor: coolingDown
            ? scheme.onSurfaceVariant.withValues(alpha: 0.5)
            : scheme.primary,
        // 与分组头「测延迟」按钮同款紧凑内距 → 两者文字右缘严格对齐。
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}

/// 空态：无可用分组 → 引导续费 + 刷新重试（R4.6，复用 XbEmptyState）。
class _EmptyNodes extends StatelessWidget {
  const _EmptyNodes({this.onTapRenew});

  final VoidCallback? onTapRenew;

  @override
  Widget build(BuildContext context) {
    return XbEmptyState(
      icon: Icons.cloud_off,
      title: '当前无可用线路',
      description: '套餐可能已到期或未生效，\n续费 / 购买套餐后即可同步线路。',
      actionLabel: '前往续费 / 购买',
      onAction: onTapRenew,
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

/// 流量用尽空态（原型桌面屏26b / 移动屏10a）：套餐流量已用尽 → 清空节点，引导
/// 购买流量包恢复本周期流量，或购买 / 更改套餐。复用 XbEmptyState（主+次按钮）。
class _ExhaustedNodes extends StatelessWidget {
  const _ExhaustedNodes({this.onBuyResetPack, this.onBuyPlan});

  /// 购买流量包（恢复本周期流量）。
  final VoidCallback? onBuyResetPack;

  /// 购买 / 更改套餐。
  final VoidCallback? onBuyPlan;

  @override
  Widget build(BuildContext context) {
    return XbEmptyState(
      icon: Icons.error_outline,
      title: '当前套餐流量已用尽',
      description: '流量用尽后线路暂不可用。\n可购买流量包恢复本周期流量，或购买 / 更改其他套餐。',
      actionLabel: '购买流量包',
      actionIcon: Icons.bolt,
      onAction: onBuyResetPack,
      secondaryLabel: '购买 / 更改套餐',
      secondaryIcon: Icons.shopping_cart,
      onSecondary: onBuyPlan,
    );
  }
}

